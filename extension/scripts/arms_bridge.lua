-- Arms Bridge: conservative 5E integration for the 2026 D20 action pipeline.
-- Original code, MIT License. No Rolemaster ruleset or table data is included.
-- Alpha contract: attack and damage must be rolled by the SAME FG client.
-- Ordinary base dice are converted; complete native critical dice are retained.
-- A separate, typed overflow supplement can exceed the ordinary weapon maximum.
-- The first eligible PHYSICAL clause supplies that base; elemental riders stay native.
local unpackValues = table.unpack or unpack
local installed, initialized = {}, false
local pending, staged, bypass = {}, {}, {}
local sequence, generation, lastNotice = 0, 0, ""
local MAX_CONTEXTS, MAX_AGE, MAX_GENERATIONS = 128, 120, 128
local sessionId = tostring({}):gsub("[^%w]", "")
local OPEN_TYPE = "arms_bridge_open"
local requestOpen, openResolved

local function finite(n)
  return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end
local function flag(v) return v == true or v == 1 or v == "1" or v == "true" end
local function copy(t)
  local result = {}; for k, v in pairs(t or {}) do result[k] = v end; return result
end
local function pack(...) return { n = select("#", ...), ... } end
local function originalCall(fn, ...)
  if fn then return pack(fn(...)) end
  return { n = 0 }
end
local function notice(message)
  lastNotice = tostring(message)
  if Comm and type(Comm.addChatMessage) == "function" then
    pcall(Comm.addChatMessage, { font = "systemfont", text = "[Arms Bridge] " .. lastNotice })
  end
end
local function requestedMode()
  if ArmsData and type(ArmsData.getMode) == "function" then
    local ok, mode = pcall(ArmsData.getMode)
    if ok and (mode == "off" or mode == "compare" or mode == "on") then return mode end
  end
  return "compare"
end
local function now()
  if os and type(os.time) == "function" then
    local ok, value = pcall(os.time); if ok and finite(value) then return value end
  end
end
local function actorId(actor)
  if not actor or not ArmsData or type(ArmsData.actorId) ~= "function" then return nil end
  local id = ArmsData.actorId(actor)
  if type(id) == "string" and id ~= "" then return id end
end
local function matches(context, source, target, weapon)
  return (not source or context.source == source) and (not target or context.target == target)
    and (not weapon or context.weapon == weapon)
end
local function discard(source, target, weapon)
  local count = 0
  for _, queue in ipairs({ pending, staged }) do
    for id, context in pairs(queue) do
      if matches(context, source, target, weapon) then
        queue[id] = nil; count = count + 1
      end
    end
  end
  return count
end
local function prune()
  local timestamp = now()
  for _, queue in ipairs({ pending, staged }) do
    for id, context in pairs(queue) do
      local age = timestamp and context.created and timestamp - context.created
      if (age and (age > MAX_AGE or age < 0)) or generation - context.generation > MAX_GENERATIONS then
        queue[id] = nil
      end
    end
  end
end
local function tick() generation = generation + 1; prune() end
local function nextId() sequence = sequence + 1; return sessionId .. ":" .. sequence end
local function limitContexts()
  local count, oldest, oldestQueue = 0
  for _, queue in ipairs({ pending, staged }) do
    for _, context in pairs(queue) do
      count = count + 1
      if not oldest or context.sequence < oldest.sequence then oldest, oldestQueue = context, queue end
    end
  end
  if count >= MAX_CONTEXTS and oldest then
    oldestQueue[oldest.id] = nil
  end
end

function getCapabilities()
  local missing = {}
  local function need(condition, name)
    if not condition then missing[#missing + 1] = name end
    return not not condition
  end
  local attack = need(installed.attack ~= nil, "ActionAttack.onPreAttackResolve")
  local ownOpenHandler = false
  if installed.openAction and ActionsManager and type(ActionsManager.getResultHandler) == "function" then
    local ok, current = pcall(ActionsManager.getResultHandler, OPEN_TYPE)
    ownOpenHandler = ok and current == installed.openAction.callback
  end
  local open = need(ownOpenHandler, "ActionsManager.registerResultHandler[arms_bridge_open]")
  open = need(ActionsManager and type(ActionsManager.getResultHandler) == "function", "ActionsManager.getResultHandler") and open
  open = need(ActionsManager and type(ActionsManager.roll) == "function", "ActionsManager.roll") and open
  local damage = need(installed.preMod ~= nil, "GameManager.onActionPreModRoll[damage]")
  damage = need(installed.preResolve ~= nil, "GameManager.onActionPreResolve[damage]") and damage
  damage = need(ActionDamageD20 and type(ActionDamageD20.getRoll) == "function", "ActionDamageD20.getRoll") and damage
  damage = need(ActionsManager and type(ActionsManager.total) == "function", "ActionsManager.total") and damage
  local engine = need(ArmsEngine and type(ArmsEngine.resolve) == "function" and type(ArmsEngine.damageDice) == "function"
    and type(ArmsEngine.damageOverflow) == "function", "ArmsEngine")
  local data = need(ArmsData and type(ArmsData.actorId) == "function" and type(ArmsData.weaponFor) == "function"
    and type(ArmsData.armorFor) == "function" and type(ArmsData.actionLabel) == "function"
    and type(ArmsData.weaponHands) == "function", "ArmsData")
  return { attack = attack, damage = damage, open = open, ready = attack and damage and open and engine and data,
    identity = installed.buildAttack ~= nil and installed.buildDamage ~= nil and installed.attackRoll ~= nil
      and installed.damageRoll ~= nil and DB ~= nil and type(DB.getPath) == "function",
    missing = missing, expirySeconds = now() and MAX_AGE or nil, maxContexts = MAX_CONTEXTS }
end
local function effectiveMode()
  local mode = requestedMode()
  if mode == "on" and not getCapabilities().ready then return "compare" end
  return mode
end
local function weaponIdentity(roll)
  local label = ArmsData.actionLabel(roll)
  if type(label) ~= "string" or label == "" or #label > 256 then return nil end
  local hands = ArmsData.weaponHands(roll)
  if hands ~= "1h" and hands ~= "2h" and hands ~= "unknown" then return nil end
  local usage = "|hands:" .. hands
  local path = roll.sArmsWeaponNode
  if type(path) == "string" and path ~= "" and #path <= 1024 then return "node:" .. path .. usage, label end
  return "label:" .. label .. usage, label
end
local function weaponTable(roll)
  local normalized = copy(roll)
  normalized.bWeapon, normalized.bSpell = flag(roll.bWeapon), flag(roll.bSpell)
  return ArmsData.weaponFor(normalized)
end
local function safe(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    if requestedMode() == "on" then discard() end
    notice("Integración suspendida para esta tirada: " .. tostring(err))
  end
end

local function updateDamageMetadata(context, roll)
  if type(roll) ~= "table" then return end
  roll.nArmsQuality, roll.nArmsOverflow = context.quality, context.overflow
end
local function validResult(result)
  return type(result) == "table" and type(result.hit) == "boolean"
    and finite(result.quality) and result.quality >= 0 and result.quality <= 1
    and finite(result.overflow) and result.overflow >= 0
    and type(result.needs_open) == "boolean" and finite(result.roll_total)
end

local resultTags = { ["[HIT]"] = true, ["[MISS]"] = true, ["[CRITICAL HIT]"] = true, ["[AUTOMATIC MISS]"] = true }
local function attackResolved(sourceActor, targetActor, roll)
  local mode = effectiveMode()
  if mode == "off" or type(roll) ~= "table" or flag(roll.bSpell) then return end
  -- A dragged/replayed roll must never create a second damage entitlement.
  if roll.sArmsAttackID ~= nil then return end
  local source, target = actorId(sourceActor), actorId(targetActor)
  if not source or not target then notice("Ataque sin un origen y objetivo únicos: resolución nativa."); return end
  local weapon, label = weaponIdentity(roll)
  if not weapon then notice("Ataque sin identidad de arma: resolución nativa."); return end
  local function fallback(message)
    if mode == "on" then discard(source, target, weapon) end
    notice(message)
  end
  if not finite(roll.nFirstDie) or roll.nFirstDie < 1 or roll.nFirstDie > 20 or roll.nFirstDie % 1 ~= 0
    or not finite(roll.nTotal) or not finite(roll.nDefenseVal) or type(roll.aMessages) ~= "table"
    or (roll.sResult ~= "hit" and roll.sResult ~= "crit" and roll.sResult ~= "miss" and roll.sResult ~= "fumble") then
    fallback("Faltan campos verificados de resolución de ataque: se conserva la tirada nativa."); return
  end
  local tableId = weaponTable(roll)
  if not tableId then fallback("Acción excluida o sin tabla de arma: " .. label .. "."); return end
  local armor, armorError = ArmsData.armorFor(targetActor, roll.nDefenseVal)
  if not armor then fallback(tostring(armorError or "Armadura sin perfil: resolución nativa.")); return end
  -- nTotal and nDefenseVal already contain native attack/defense effects.
  -- Calling getDefenseValue again can evaluate or consume effects twice.
  local result, err = ArmsEngine.resolve({ natural = roll.nFirstDie, attack_bonus = roll.nTotal - roll.nFirstDie,
    defense = armor.defense, armor = armor.armor, weapon = tableId, crit = roll.sResult == "crit" })
  if not validResult(result) then
    fallback("Tabla no aplicable: " .. tostring(err or "resultado inválido") .. "."); return
  end
  local resultName = result.critical and "crit" or (result.hit and "hit" or (roll.nFirstDie == 1 and "fumble" or "miss"))
  if mode == "compare" then
    if result.critical then
      notice(string.format("Comparación local de %s: D&D %s; crítico D&D%s. Sin cambios.", label, roll.sResult,
        result.needs_open and "; el 20 abriría otra tirada" or "; daño nativo más suplemento de tabla"))
    else
      notice(string.format("Comparación local de %s: D&D %s; tabla %s, calidad %.3f. Sin cambios.", label, roll.sResult, resultName, result.quality))
    end
    return
  end
  tick()
  local messages = {}
  for _, message in ipairs(roll.aMessages) do if not resultTags[message] then messages[#messages + 1] = message end end
  messages[#messages + 1] = resultName == "crit" and "[CRITICAL HIT]" or (resultName == "hit" and "[HIT]"
    or (resultName == "fumble" and "[AUTOMATIC MISS]" or "[MISS]"))
  messages[#messages + 1] = result.needs_open and "[ARMS OPEN PENDING]" or (result.critical
    and "[ARMS CRITICAL NATIVE]" or string.format("[ARMS Q %.3f]", result.quality))
  local id = nextId()
  -- Change the result before native critical-state, chat, targeting and OOB code.
  roll.sResult, roll.aMessages, roll.sArmsAttackID = resultName, messages, id
  if not result.hit then discard(source, target, weapon); return end
  limitContexts()
  local context = { id = id, source = source, target = target, weapon = weapon, label = label, tableId = tableId,
    quality = result.quality, critical = result.critical, index = result.index, created = now(),
    overflow = result.overflow, rollTotal = result.roll_total, opening = result.needs_open,
    generation = generation, sequence = sequence, state = result.needs_open and "opening" or "pending" }
  pending[id] = context
  if result.needs_open then
    context.openRoll = { roll.nFirstDie }
    context.resolveOptions = { natural = roll.nFirstDie, attack_bonus = roll.nTotal - roll.nFirstDie,
      defense = armor.defense, armor = armor.armor, weapon = tableId, crit = roll.sResult == "crit" }
    context.sourceActor, context.secret, context.tower, context.user = sourceActor, flag(roll.bSecret), flag(roll.bTower), roll.sUser
    requestOpen(context)
  end
end

local function dieSides(spec)
  if type(spec) == "table" then spec = spec.type end
  if type(spec) ~= "string" then return nil end
  -- Standard and native coloured dice only; no negative/custom/exploding dice.
  local sides = tonumber(spec:lower():match("^[dgprby](%d+)$"))
  if sides and sides >= 1 and sides <= 100 then return sides end
end
local function abandonOpen(context, message)
  pending[context.id], staged[context.id] = nil, nil
  notice(message)
end
requestOpen = function(context)
  context.openToken = nextId()
  local roll = { sType = OPEN_TYPE, aDice = { "d20" }, nMod = 0,
    sDesc = "[ARMS OPEN] " .. context.label,
    sArmsContextID = context.id, sArmsOpenToken = context.openToken,
    sArmsSourceID = context.source, sArmsTargetID = context.target,
    bSecret = context.secret, bTower = context.tower, sUser = context.user }
  -- Start AFTER modifiers: a continuation is a plain d20, with no second
  -- advantage/disadvantage selection, attack effects or modifier-stack use.
  local ok, err = pcall(ActionsManager.roll, context.sourceActor, nil, roll, false)
  if not ok then abandonOpen(context, "No se pudo lanzar la continuación: " .. tostring(err)) end
end
openResolved = function(sourceActor, _, roll)
  if type(roll) ~= "table" or roll.sType ~= OPEN_TYPE then return end
  tick()
  local context = type(roll.sArmsContextID) == "string" and (pending[roll.sArmsContextID] or staged[roll.sArmsContextID])
  if not context or not context.opening or context.openToken ~= roll.sArmsOpenToken then return end
  if actorId(sourceActor) ~= context.source or roll.sArmsSourceID ~= context.source
    or roll.sArmsTargetID ~= context.target then return end
  -- A matching launch token is consumed before examining its outcome. A
  -- dragged result or duplicate delivery cannot add the same d20 twice.
  context.openToken = nil
  if effectiveMode() ~= "on" then
    pending[context.id], staged[context.id] = nil, nil; return
  end
  local die = type(roll.aDice) == "table" and roll.aDice[1]
  local expression = type(roll.aDice) == "table" and roll.aDice.expr
  local plainExpression = expression == nil or expression == "" or (type(expression) == "string"
    and (expression:lower():gsub("%s", "") == "d20" or expression:lower():gsub("%s", "") == "1d20"))
  if type(die) ~= "table" or #roll.aDice ~= 1 or dieSides(die) ~= 20 or die.dropped
    or not finite(die.result) or die.result % 1 ~= 0 or die.result < 1 or die.result > 20
    or tonumber(roll.nMod) ~= 0 or not plainExpression
    or (die.value ~= nil and die.value ~= die.result) then
    abandonOpen(context, "Continuación alterada o incompatible: se abandona la apertura sin suplemento parcial."); return
  end
  context.openRoll[#context.openRoll + 1] = die.result
  local options = copy(context.resolveOptions); options.open_roll = context.openRoll
  local result, err = ArmsEngine.resolve(options)
  if not validResult(result) or not result.hit then
    abandonOpen(context, "No se pudo resolver la apertura: " .. tostring(err or "resultado inválido")); return
  end
  context.quality, context.overflow, context.index = result.quality, result.overflow, result.index
  context.rollTotal, context.opening = result.roll_total, result.needs_open
  context.created, context.generation = now(), generation
  local shown = copy(roll)
  shown.bSecret, shown.bTower, shown.sUser = context.secret, context.tower, context.user
  shown.sDesc = "[ARMS OPEN] " .. context.label .. ": " .. table.concat(context.openRoll, "+")
    .. " = " .. tostring(context.rollTotal) .. (context.opening and " [CONTINUES]" or " [COMPLETE]")
  Comm.deliverChatMessage(ActionsManager.createActionMessage(sourceActor, shown))
  if context.opening then
    requestOpen(context); return
  end
  context.state = "pending"
end
local physicalTypes = { bludgeoning = true, piercing = true, slashing = true }
local damageTypes = { acid = true, bludgeoning = true, cold = true, fire = true, force = true,
  lightning = true, necrotic = true, piercing = true, poison = true, psychic = true,
  radiant = true, slashing = true, thunder = true }
local damageTags = { magic = true, magical = true, silver = true, silvered = true,
  adamantine = true, ["cold iron"] = true, coldiron = true, critical = true,
  precision = true, nonlethal = true, weapon = true, spell = true, opportunity = true }
local function damageTypeInfo(value)
  local info = { types = {}, tags = {}, signature = {}, physical = false, unknown = false, critical = false }
  if type(value) ~= "string" then return info end
  local seen = {}
  for token in value:lower():gmatch("[^,]+") do
    token = token:match("^%s*(.-)%s*$")
    if token ~= "" and not seen[token] then
      seen[token] = true; info.signature[#info.signature + 1] = token
      if damageTypes[token] then
        info.types[#info.types + 1] = token
        if physicalTypes[token] then info.physical = true end
      elseif damageTags[token] then
        info.tags[token] = true
        if token == "critical" then info.critical = true end
      else info.unknown = true end
    end
  end
  table.sort(info.signature); info.signature = table.concat(info.signature, ",")
  return info
end
local function physicalBase(roll)
  if type(roll.clauses) ~= "table" or #roll.clauses < 1 or #roll.clauses > 128
    or type(roll.aDice) ~= "table" then
    return nil, "No hay cláusulas de daño compatibles para localizar el componente físico."
  end
  local selected, offset, prefix = nil, 0, {}
  for clauseIndex, clause in ipairs(roll.clauses) do
    if type(clause) ~= "table" or type(clause.dice) ~= "table" then
      return nil, "No se puede verificar el orden de los componentes de daño."
    end
    local info = damageTypeInfo(clause.dmgtype)
    if info.physical and #info.types > 1 then
      return nil, "Una cláusula mezcla daño físico con otro tipo de daño; sepáralos en componentes distintos."
    end
    if info.physical and info.unknown then
      return nil, "La cláusula física contiene un tipo o etiqueta desconocido; revisa sus componentes antes de convertirla."
    end
    local eligible = info.physical and not info.critical and not flag(clause.bCritical) and not info.tags.precision
    if not selected and eligible then
      if #clause.dice < 1 or #clause.dice > 32 then
        return nil, "El componente físico base no contiene un grupo de dados compatible."
      end
      selected = { clauseIndex = clauseIndex, start = offset + 1, specs = {}, prefix = copy(prefix),
        damageType = info.types[1], signature = info.signature }
      local maximumSum = 0
      for i, die in ipairs(clause.dice) do
        local index, sides = offset + i, dieSides(die)
        if not sides or type(roll.aDice[index]) ~= "table" or dieSides(roll.aDice[index]) ~= sides or roll.aDice[index].dropped then
          return nil, "Los dados físicos no coinciden con su cláusula y posición originales."
        end
        selected.specs[i] = "d" .. sides; maximumSum = maximumSum + sides
      end
      if maximumSum > 2000 then return nil, "Grupo de dados físicos demasiado grande." end
    elseif not selected then
      -- A preceding rider contributes only to the offset, never to the base
      -- distribution. Verify its layout so a shorthand/custom die cannot shift it.
      for i, die in ipairs(clause.dice) do
        local index, sides = offset + i, dieSides(die)
        if not sides or type(roll.aDice[index]) ~= "table" or dieSides(roll.aDice[index]) ~= sides or roll.aDice[index].dropped then
          return nil, "Un componente anterior impide verificar la posición de los dados físicos."
        end
        prefix[#prefix + 1] = "d" .. sides
      end
    end
    offset = offset + #clause.dice
  end
  if not selected then return nil, "No hay una cláusula física base compatible: los componentes conservan su daño nativo por tipo." end
  return selected
end
local function bypassRequested(source)
  if bypass["*"] then bypass["*"] = nil; return true end
  if source and bypass[source] then bypass[source] = nil; return true end
  return false
end
local function damagePreMod(sourceActor, targetActor, roll)
  if effectiveMode() ~= "on" or type(roll) ~= "table" or roll.sType ~= "damage" then return end
  tick()
  local source, target = actorId(sourceActor), actorId(targetActor)
  local weapon = weaponIdentity(roll)
  if bypassRequested(source) then
    if source then discard(source, target, weapon) end
    notice("Próximo daño: conversión omitida por /arms bypass."); return
  end
  if flag(roll.bSpell) or flag(roll.bOngoing) then return end
  if roll.sArmsContextID ~= nil or flag(roll.bArmsConverted) or flag(roll.bArmsOverflowApplied) then
    -- Re-entering the modifier pipeline indicates a replay, not a fresh roll.
    if type(roll.sArmsContextID) == "string" then staged[roll.sArmsContextID] = nil end
    return
  end
  if not source or not target or not weapon then
    if source then discard(source, nil, weapon) end
    notice("Daño sin un único objetivo o identidad de arma: tirada nativa. Selecciona un solo objetivo."); return
  end
  local found, count = nil, 0
  for _, context in pairs(pending) do
    if matches(context, source, target, weapon) then found = context; count = count + 1 end
  end
  if count ~= 1 then
    if count > 1 then
      discard(source, target, weapon)
      notice("Varios ataques pendientes de la misma arma y objetivo: descartados. Alterna ataque y daño.")
    else notice("Sin ataque pendiente de esa arma y objetivo en este cliente: daño nativo.") end
    return
  end
  -- Claim exactly once even if a later validation fails. A later damage roll
  -- must not accidentally use an earlier attack after a native fallback.
  pending[found.id] = nil
  if found.opening then
    notice("Daño solicitado antes de terminar la apertura: daño nativo completo y contexto descartado. Espera al cierre de la cadena antes de tirar daño.")
    return
  end
  if not found.opening and found.overflow == 0 and (found.critical or flag(roll.bCritical)) then
    notice("Crítico D&D: se conserva el daño nativo completo."); return
  end
  if weaponTable(roll) ~= found.tableId then notice("Cambió la tabla o acción de daño: tirada nativa."); return end
  local base, err = physicalBase(roll)
  if not base then notice(err .. " Se conserva el daño nativo."); return end
  local specs = base.specs
  local supplement, supplementError = ArmsEngine.damageOverflow(specs, found.overflow)
  if not finite(supplement) or supplement % 1 ~= 0 or supplement < 0 then
    notice("Suplemento de daño no válido: " .. tostring(supplementError or "resultado inválido") .. ". Daño nativo."); return
  end
  if supplement > 0 then
    local baseModifier = roll.clauses[base.clauseIndex].modifier
    if not finite(roll.nMod) or not finite(baseModifier)
      or not finite(roll.nMod + supplement) or not finite(baseModifier + supplement) then
      notice("La cláusula física no admite un suplemento verificable: daño nativo."); return
    end
    -- This hook is BEFORE native critical/effect processing and encoding. Keep
    -- the supplement in the selected PHYSICAL type and aggregate modifier;
    -- native D20 code then builds displays, damage types and the final total.
    local clauses = copy(roll.clauses); clauses[base.clauseIndex] = copy(clauses[base.clauseIndex])
    clauses[base.clauseIndex].modifier = baseModifier + supplement
    roll.clauses, roll.nMod = clauses, roll.nMod + supplement
    roll.bArmsOverflowApplied = true
    roll.sDesc = tostring(roll.sDesc or "") .. string.format(" [ARMS OVERFLOW +%d]", supplement)
  end
  found.specs, found.state, found.generation, found.supplement = specs, "staged", generation, supplement
  found.baseStart, found.baseClause, found.baseType = base.start, base.clauseIndex, base.damageType
  found.baseSignature, found.prefixSpecs = base.signature, base.prefix
  staged[found.id] = found
  -- Only scalar roll metadata: survives normal FG drag/roll serialization.
  roll.sArmsContextID, roll.sArmsSourceID, roll.sArmsTargetID = found.id, source, target
  roll.sArmsWeaponKey, roll.sArmsBaseDice = weapon, table.concat(specs, ",")
  roll.nArmsBaseDice = #specs
  roll.nArmsBaseStart, roll.nArmsBaseClause = base.start, base.clauseIndex
  roll.sArmsBaseType, roll.sArmsPrefixDice = base.signature, table.concat(base.prefix, ",")
  roll.nArmsSupplement = supplement
  updateDamageMetadata(found, roll)
end

local function simpleExpression(dice)
  local expression = dice.expr
  if expression == nil or expression == "" then return true end
  if type(expression) ~= "string" then return false end
  expression = expression:lower():gsub("%s", "")
  if expression == "" or expression:sub(1, 1) == "+" or expression:sub(-1) == "+" or expression:find("++", 1, true) then return false end
  local index = 1
  for term in expression:gmatch("[^+]+") do
    local count, sides = term:match("^(%d*)[dgprby](%d+)$")
    if not sides then return false end
    count, sides = tonumber(count) or 1, tonumber(sides)
    if count < 1 or count > 128 then return false end
    for _ = 1, count do
      if type(dice[index]) ~= "table" or dieSides(dice[index]) ~= sides or dice[index].dropped then return false end
      index = index + 1
    end
  end
  return index - 1 == #dice
end
local function damagePreResolve(sourceActor, targetActor, roll)
  if effectiveMode() ~= "on" or type(roll) ~= "table" or roll.sType ~= "damage" or flag(roll.bArmsConverted) then return end
  tick()
  local context = type(roll.sArmsContextID) == "string" and staged[roll.sArmsContextID]
  if not context then return end
  -- A token is useful only once and only in the originating executor's memory.
  staged[context.id] = nil
  local function fallback(message)
    if context.supplement and context.supplement > 0 then
      notice(message .. string.format(" Se conserva el daño ya preparado, incluido el suplemento de tabla +%d.", context.supplement))
    else notice(message .. " Se conserva el daño nativo.") end
  end
  if context.opening then
    abandonOpen(context, "El daño alcanzó la resolución antes de cerrar la apertura: resolución nativa sin suplemento."); return
  end
  -- Native critical dice are never quantile-replaced. A typed overflow already
  -- entered the native modifier pipeline once; do not add or double it here.
  if context.critical or flag(roll.bCritical) then
    notice("Crítico D&D: dados nativos completos" .. (context.supplement > 0
      and string.format(" y suplemento de tabla +%d preparado una vez.", context.supplement) or ".")); return
  end
  local source, target = actorId(sourceActor), actorId(targetActor)
  local weapon = weaponIdentity(roll)
  local serializedQuality = tonumber(roll.nArmsQuality)
  local serializedOverflow = tonumber(roll.nArmsOverflow)
  if source ~= context.source or target ~= context.target or weapon ~= context.weapon
    or roll.sArmsSourceID ~= source or roll.sArmsTargetID ~= target or roll.sArmsWeaponKey ~= weapon
    or tonumber(roll.nArmsBaseDice) ~= #context.specs or not finite(serializedQuality)
    or tonumber(roll.nArmsBaseStart) ~= context.baseStart or tonumber(roll.nArmsBaseClause) ~= context.baseClause
    or roll.sArmsBaseType ~= context.baseSignature or roll.sArmsPrefixDice ~= table.concat(context.prefixSpecs, ",")
    or math.abs(serializedQuality - context.quality) > 1e-12
    or not finite(serializedOverflow) or math.abs(serializedOverflow - context.overflow) > 1e-9
    or tonumber(roll.nArmsSupplement) ~= context.supplement
    or roll.sArmsBaseDice ~= table.concat(context.specs, ",") or flag(roll.bSpell) or flag(roll.bOngoing) then
    fallback("Contexto de daño cambiado, reutilizado o recibido de otro cliente."); return
  end
  if type(roll.aDice) ~= "table" or not finite(roll.nMod) or not simpleExpression(roll.aDice) then
    fallback("Expresión o modificador de daño no compatible."); return
  end
  if type(roll.clauses) == "table" then
    local current = physicalBase(roll)
    if not current or current.start ~= context.baseStart or current.clauseIndex ~= context.baseClause
      or current.signature ~= context.baseSignature or table.concat(current.specs, ",") ~= table.concat(context.specs, ",")
      or table.concat(current.prefix, ",") ~= table.concat(context.prefixSpecs, ",") then
      fallback("Cambió la cláusula física o el orden de los componentes de daño."); return
    end
  end
  for i, spec in ipairs(context.prefixSpecs) do
    local die = roll.aDice[i]
    if type(die) ~= "table" or dieSides(die) ~= dieSides(spec) or die.dropped then
      fallback("Cambió un componente anterior al daño físico."); return
    end
  end
  local originalResults = {}
  for i, spec in ipairs(context.specs) do
    local die = roll.aDice[context.baseStart + i - 1]
    if type(die) ~= "table" or dieSides(die) ~= dieSides(spec) or die.dropped or not finite(die.result) then
      fallback("Cambió el orden o tipo de los dados base."); return
    end
    if type(die.dmgtype) == "string" and die.dmgtype ~= "" then
      local info = damageTypeInfo(die.dmgtype)
      if not info.physical or #info.types ~= 1 or info.types[1] ~= context.baseType or info.unknown then
        fallback("El dado seleccionado ya no conserva su tipo físico original."); return
      end
    end
    originalResults[i] = die.result
  end
  local results, err = ArmsEngine.damageDice(context.specs, context.quality)
  if type(results) ~= "table" or #results ~= #context.specs then
    fallback("No se pudo convertir el daño: " .. tostring(err or "grupo inválido") .. "."); return
  end
  local dice = copy(roll.aDice)
  for i, result in ipairs(results) do
    if not finite(result) or result % 1 ~= 0 or result < 1 or result > dieSides(context.specs[i]) then
      fallback("Resultado de daño no válido."); return
    end
    local index = context.baseStart + i - 1
    dice[index] = copy(roll.aDice[index]); dice[index].result, dice[index].value = result, result
  end
  -- Recompute from actual values; cached expression totals describe the old dice.
  -- Only an absent or verified additive standard-dice expression reaches here.
  dice.expr, dice.total = nil, nil
  local candidate = copy(roll); candidate.aDice = dice
  local total = ActionsManager.total(candidate)
  if not finite(total) then fallback("No se pudo recalcular el total."); return end
  -- Commit only after all validations and total calculation have succeeded.
  roll.aDice, roll.nTotal, roll.bArmsConverted = dice, total, true
  roll.sArmsOriginalBase, roll.sArmsResolvedBase = table.concat(originalResults, ","), table.concat(results, ",")
  roll.sDesc = tostring(roll.sDesc or "") .. string.format(" [ARMS BASE Q %.3f]", context.quality)
end

local function registerOpenAction()
  if not GameSystem or type(GameSystem.actions) ~= "table" or GameSystem.actions[OPEN_TYPE] ~= nil
    or not ActionsManager or type(ActionsManager.registerResultHandler) ~= "function"
    or type(ActionsManager.getResultHandler) ~= "function"
    or type(ActionsManager.unregisterResultHandler) ~= "function"
    or type(ActionsManager.createActionMessage) ~= "function"
    or not Comm or type(Comm.deliverChatMessage) ~= "function" then return end
  local definition = { bUseModStack = false }
  GameSystem.actions[OPEN_TYPE] = definition
  local callback = function(...) safe(openResolved, ...) end
  local ok = pcall(ActionsManager.registerResultHandler, OPEN_TYPE, callback)
  if ok then installed.openAction = { definition = definition, callback = callback }
  else GameSystem.actions[OPEN_TYPE] = nil end
end

local function hookField(key, object, field, after)
  if not object or type(object[field]) ~= "function" then return end
  local original = object[field]
  local wrapper = function(...)
    local values = originalCall(original, ...)
    safe(after, values, ...)
    return unpackValues(values, 1, values.n)
  end
  object[field] = wrapper
  installed[key] = { object = object, field = field, original = original, wrapper = wrapper }
end
local function hookSlot(key, slot, callback)
  if not GameManager or type(GameManager.getMultiKeyFunction) ~= "function" or type(GameManager.setMultiKeyFunction) ~= "function" then return end
  local ok, original = pcall(GameManager.getMultiKeyFunction, slot, "damage")
  if not ok or (original ~= nil and type(original) ~= "function") then return end
  local wrapper = function(...)
    local values = originalCall(original, ...)
    safe(callback, ...)
    return unpackValues(values, 1, values.n)
  end
  local success = pcall(GameManager.setMultiKeyFunction, slot, "damage", wrapper)
  if success then installed[key] = { slot = slot, original = original, wrapper = wrapper } end
end
local function captureWeapon(values, _, nodeWeapon)
  if effectiveMode() ~= "on" or type(values[1]) ~= "table" or not nodeWeapon or not DB or type(DB.getPath) ~= "function" then return end
  local path = DB.getPath(nodeWeapon)
  if type(path) == "string" and path ~= "" then values[1].sArmsWeaponNode = path end
  if type(ArmsData.captureWeaponMetadata) == "function" then ArmsData.captureWeaponMetadata(values[1], nodeWeapon) end
end
local function propagateWeapon(values, _, action)
  if effectiveMode() ~= "on" or type(values[1]) ~= "table" or type(action) ~= "table" then return end
  if type(action.sArmsWeaponNode) == "string" and action.sArmsWeaponNode ~= "" then
    values[1].sArmsWeaponNode = action.sArmsWeaponNode
  end
  for _, field in ipairs({ "sArmsHands", "sArmsCategory", "sArmsGroup" }) do
    if type(action[field]) == "string" and action[field] ~= "" then values[1][field] = action[field] end
  end
end

function onInit()
  if initialized then return end
  initialized = true
  registerOpenAction()
  hookField("attack", ActionAttack, "onPreAttackResolve", function(_, ...) attackResolved(...) end)
  hookSlot("preMod", "onActionPreModRoll", damagePreMod)
  hookSlot("preResolve", "onActionPreResolve", damagePreResolve)
  hookField("buildAttack", CharWeaponManager, "buildAttackAction", captureWeapon)
  hookField("buildDamage", CharWeaponManager, "buildDamageAction", captureWeapon)
  hookField("attackRoll", ActionAttack, "getRoll", propagateWeapon)
  hookField("damageRoll", ActionDamageD20, "getRoll", propagateWeapon)
  if not getCapabilities().ready then notice("Integración incompleta: la conversión queda en comparación. Usa /arms status.") end
end
function onClose()
  discard()
  for _, item in pairs(installed) do
    if item.definition then
      if GameSystem and type(GameSystem.actions) == "table" and GameSystem.actions[OPEN_TYPE] == item.definition then
        local ok, current = pcall(ActionsManager.getResultHandler, OPEN_TYPE)
        if ok and current == item.callback then
          pcall(ActionsManager.unregisterResultHandler, OPEN_TYPE)
          GameSystem.actions[OPEN_TYPE] = nil
        end
      end
    elseif item.slot then
      if GameManager and type(GameManager.getMultiKeyFunction) == "function" and type(GameManager.setMultiKeyFunction) == "function" then
        local ok, current = pcall(GameManager.getMultiKeyFunction, item.slot, "damage")
        if ok and current == item.wrapper then pcall(GameManager.setMultiKeyFunction, item.slot, "damage", item.original) end
      end
    elseif item.object[item.field] == item.wrapper then item.object[item.field] = item.original end
  end
  installed, initialized, pending, staged, bypass = {}, false, {}, {}, {}
end
function getPending()
  prune()
  local entries = {}
  for _, queue in ipairs({ pending, staged }) do
    for _, context in pairs(queue) do
      entries[#entries + 1] = { id = context.id, source = context.source, target = context.target, weapon = context.weapon,
        label = context.label, quality = context.quality, overflow = context.overflow, rollTotal = context.rollTotal,
        created = context.created, state = context.state, sequence = context.sequence }
    end
  end
  table.sort(entries, function(a, b) return a.sequence < b.sequence end)
  return entries
end
function clearPending(source, target)
  if source ~= nil and type(source) ~= "string" then source = actorId(source); if not source then return 0 end end
  if target ~= nil and type(target) ~= "string" then target = actorId(target); if not target then return 0 end end
  return discard(source, target)
end
function bypassNext(source)
  if source ~= nil and type(source) ~= "string" then source = actorId(source); if not source then return nil end end
  bypass[source or "*"] = true
  return true
end
function status()
  local capability = getCapabilities()
  return { requestedMode = requestedMode(), effectiveMode = effectiveMode(), ready = capability.ready,
    missing = capability.missing, pendingCount = #getPending(), lastNotice = lastNotice }
end

return { onInit = onInit, onClose = onClose, status = status, getCapabilities = getCapabilities,
  getPending = getPending, clearPending = clearPending, bypassNext = bypassNext }
