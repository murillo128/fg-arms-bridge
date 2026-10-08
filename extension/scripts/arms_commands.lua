-- Arms Bridge: chat controls and explicit, data-only table import. MIT License.
local function say(s)
  local msg={font="systemfont",text="[Arms Bridge] "..tostring(s)}
  if Comm and Comm.addChatMessage then Comm.addChatMessage(msg) end
  return tostring(s)
end
function tokenize(s)
  local out,part={},{}; local quote=false; local started=false; local i=1
  s=tostring(s or "")
  while i<=#s do
    local c=s:sub(i,i)
    if c=='"' then quote=not quote; started=true
    elseif c=="\\" and quote and s:sub(i+1,i+1)=='"' then table.insert(part,'"'); i=i+1
    elseif c:match("%s") and not quote then
      if started then table.insert(out,table.concat(part)); part={}; started=false end
    else table.insert(part,c); started=true end
    i=i+1
  end
  if quote then return nil,"Falta cerrar comillas." end
  if started then table.insert(out,table.concat(part)) end
  return out
end
function help()
  return say("/arms abre el panel. /arms status muestra diagnóstico.\n"..
    "/arms mode compare|on|off — comparar, aplicar o desactivar.\n"..
    "/arms actors — nombres y rutas del combat tracker.\n"..
    "/arms armor \"Nombre\" mail 16 — perfil y CA base de la protección material.\n"..
    "/arms armor \"Nombre\" unarmored 10 — protección sin armadura.\n"..
    "/arms armor \"Nombre\" natural_scales 16 — escamas; CA material asignada expresamente.\n"..
    "/arms armor \"Nombre\" auto — quitar asignación manual.\n"..
    "/arms weapon \"Nombre de acción\" bladed [martial] [1h] — tabla y, opcionalmente, categoría y uso. off excluye.\n"..
    "/arms catalog [\"Nombre de arma\"] [1h|2h] — grupos o clasificación de una acción.\n"..
    "/arms tables — tablas cargadas. /arms pending — ataques pendientes.\n"..
    "/arms clear — descartar pendientes. /arms bypass — próximo daño sin conversión.\n"..
    "/arms preview sword mail 16 5 2 1d8+3 — cálculo sin modificar la partida.\n"..
    "/arms preview sword plate 20+10 5 0 1d8+3 — tirada abierta; cada 20 permite continuar.\n"..
    "Las tablas incluidas son originales de demostración, no tablas oficiales de Arms Law.")
end
function showStatus()
  local st=ArmsBridge.status()
  say("v"..ArmsData.getVersion().." | modo "..tostring(st.requestedMode).." (efectivo "..tostring(st.effectiveMode)..")"..
    " | integración "..(st.ready and "disponible" or "incompleta").." | pendientes "..tostring(st.pendingCount or 0))
  if st.missing and #st.missing>0 then say("No disponibles: "..table.concat(st.missing,", ")) end
  if st.lastNotice and st.lastNotice~="" then say(st.lastNotice) end
  return st
end
function openPanel()
  if Interface and Interface.openWindow then
    local ok,win=pcall(Interface.openWindow,"arms_bridge",ArmsData.isHost() and "armsbridge" or "")
    if ok and win then return win end
  end
  return help()
end
function setMode(mode)
  if mode=="on" and not ArmsBridge.getCapabilities().ready then
    say("No se puede activar la conversión: faltan puntos de integración. Consulta /arms status.")
    return nil
  end
  local ok,err=ArmsData.setMode(mode)
  if not ok then say(err); return nil end
  ArmsBridge.clearPending()
  say("Modo "..mode..". Se han descartado los ataques pendientes.")
  return true
end
function importCSV(csv)
  local ok,err=ArmsData.importTables(csv)
  if not ok then say("Importación rechazada: "..tostring(err)); return nil,err end
  ArmsBridge.clearPending()
  say("Tablas importadas. Se han descartado los ataques pendientes; revisa /arms tables.")
  return true
end
local function formula(s)
  local count,sides,mod=tostring(s or ""):lower():match("^(%d*)d(%d+)([+-]%d+)$")
  if not sides then count,sides=tostring(s or ""):lower():match("^(%d*)d(%d+)$"); mod="0" end
  count=tonumber(count) or 1; sides=tonumber(sides); mod=tonumber(mod)
  if not sides or not mod or mod~=mod or math.abs(mod)>1000000 or sides<1 or sides>100 or count<1 or count>32 then return nil end
  local dice={}; for _=1,count do table.insert(dice,"d"..sides) end
  return dice,mod
end
local function attackSequence(text)
  if type(text)~="string" or not text:match("^%d[%d+]*$") or text:sub(-1)=="+" or text:find("++",1,true) then
    return nil,"Tirada esperada: 16, 20+10 o 20+20+10. Solo un 20 abre otra tirada."
  end
  local sequence={}
  for face in text:gmatch("[^+]+") do sequence[#sequence+1]=tonumber(face) end
  return sequence
end
local function previewArgs(args)
  if #args~=7 then return say("Uso: /arms preview sword mail 16 5 2 1d8+3; admite 20+10 como tirada.") end
  local sequence,sequenceError=attackSequence(args[4]); if not sequence then return say(sequenceError) end
  local r,err=ArmsEngine.resolve({weapon=args[2],armor=args[3],natural=sequence[1],open_roll=sequence,
    attack_bonus=tonumber(args[5]),defense=tonumber(args[6])})
  if not r then return say(err) end
  if not r.hit then return say("Fila "..tostring(r.index)..": fallo. Cálculo de prueba; no se ha aplicado daño.") end
  if r.needs_open then
    return say(string.format("Tirada %s = %d | crítico D&D; continuación pendiente: añade otro d20 a la secuencia. No se ha calculado ni aplicado daño.",args[4],r.roll_total))
  end
  local spec,modifier=formula(args[7]); if not spec then return say("Daño esperado, por ejemplo: 1d8+3 o 2d6+4.") end
  local extra,extraError=ArmsEngine.damageOverflow(spec,r.overflow); if not extra then return say(extraError) end
  local prefix=string.format("Fila %s | tirada %s = %d",tostring(r.index),args[4],r.roll_total)
  if r.critical then
    return say(string.format("%s | crítico D&D: daño nativo completo (%dd%s%+d para esta base), +%d por exceso de tabla. Los dados críticos y el modificador se cuentan una sola vez. No se ha aplicado daño.",
      prefix,2*#spec,spec[1]:sub(2),modifier,extra))
  end
  local dice,derr=ArmsEngine.damageDice(spec,r.quality); if not dice then return say(derr) end
  local total=modifier; for _,v in ipairs(dice) do total=total+v end
  if extra==0 then
    return say(string.format("%s | calidad %.3f | dados base [%s] %+d = %d. No se ha aplicado daño.",prefix,r.quality,table.concat(dice,","),modifier,total))
  end
  return say(string.format("%s | calidad %.3f | dados base [%s] %+d +%d por exceso = %d. No se ha aplicado daño.",prefix,r.quality,table.concat(dice,","),modifier,extra,total+extra))
end
local function showCatalog(args)
  if not ArmsCatalog or type(ArmsCatalog.getGroups)~="function" then return say("Catálogo no disponible.") end
  if #args==1 then
    local lines={"Grupos de la campaña; simple/martial y 1h/2h son atributos separados:"}
    for _,group in ipairs(ArmsCatalog.getGroups()) do
      lines[#lines+1]=group.id.." — "..group.label.." ("..#ArmsCatalog.listWeapons(group.id).." armas)"
    end
    lines[#lines+1]="Consulta una acción con /arms catalog \"Longsword\" 2h. Las maestrías las conserva D&D."
    return say(table.concat(lines,"\n"))
  end
  if #args>3 or (args[3] and args[3]~="1h" and args[3]~="2h") then
    return say('Uso: /arms catalog "Longsword" [1h|2h]')
  end
  local profile=ArmsData.weaponProfile({bWeapon=true,sLabel=args[2],sArmsHands=args[3]})
  if not profile then return say("Acción sin clasificación o excluida: "..args[2]..". Usa /arms weapon para asignarla.") end
  return say(string.format("%s | grupo %s | categoría %s | uso %s | propiedad %s | tabla %s. El uso desconocido no se infiere de los dados.",
    args[2],profile.group,profile.category,profile.hands,profile.hands_property,profile.table_id))
end
function onSlashCommand(_, params)
  local args,err=tokenize(params)
  if not args then return say(err) end
  local cmd=(args[1] or ""):lower()
  if cmd=="" or cmd=="import" then return openPanel() end
  if cmd=="help" then return help() end
  if cmd=="status" then return showStatus() end
  if cmd=="catalog" then return showCatalog(args) end
  if cmd=="mode" then return setMode(args[2]) end
  if cmd=="actors" then
    for _,a in ipairs(ArmsData.listActors()) do say(a.name.." — "..a.path) end
    return
  end
  if cmd=="armor" then
    if #args<3 then return say('Uso: /arms armor "Nombre" mail 16') end
    local actor,e=ArmsData.findActor(args[2]); if not actor then return say(e) end
    local ok,e2=ArmsData.setArmor(actor,args[3],args[4]); if not ok then return say(e2) end
    ArmsBridge.clearPending(); return say("Protección actualizada para "..args[2]..".")
  end
  if cmd=="weapon" then
    if #args<3 or #args>5 then return say('Uso: /arms weapon "Nombre de acción" bladed [simple|martial|custom|auto] [1h|2h|auto]') end
    local ok,e=ArmsData.mapWeapon(args[2],args[3],args[4],args[5]); if not ok then return say(e) end
    ArmsBridge.clearPending(); return say("Acción "..args[2]..": "..args[3]..".")
  end
  if cmd=="tables" then
    for _,id in ipairs(ArmsEngine.listTables()) do
      local def=ArmsEngine.getTable(id); local armors={}
      for a,_ in pairs(def.armors or {}) do table.insert(armors,a) end; table.sort(armors)
      say(id.." ("..table.concat(armors,", ")..") — "..tostring(def.provenance or "origen no indicado"))
    end
    return
  end
  if cmd=="pending" then
    local q=ArmsBridge.getPending()
    if #q==0 then return say("Sin ataques pendientes.") end
    for _,v in ipairs(q) do
      local state=v.state=="opening" and "tirada abierta en curso" or (v.state=="staged" and "daño en curso" or "listo para daño")
      say(tostring(v.label or v.weapon).." -> "..tostring(v.target).." | "..state.." | "..tostring(v.id))
    end
    return
  end
  if cmd=="clear" then return say("Pendientes descartados: "..tostring(ArmsBridge.clearPending())) end
  if cmd=="bypass" then ArmsBridge.bypassNext(); return say("El próximo daño de este cliente conservará su tirada nativa.") end
  if cmd=="preview" then return previewArgs(args) end
  return help()
end
function onInit()
  if Comm and Comm.registerSlashHandler then Comm.registerSlashHandler("arms",onSlashCommand) end
end
return {tokenize=tokenize,onSlashCommand=onSlashCommand,onInit=onInit,help=help,
  showStatus=showStatus,openPanel=openPanel,setMode=setMode,importCSV=importCSV}
