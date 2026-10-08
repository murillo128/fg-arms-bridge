-- Contract tests with a real combat engine and isolated, mocked FG APIs.
-- These do not assert that an uninstalled Fantasy Grounds build uses the hooks.
local checks = 0
local function check(value, message)
  checks = checks + 1; assert(value, message or ("bridge check " .. checks))
end
local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}; for k, v in pairs(value) do result[k] = clone(v) end; return result
end
local function equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
local function loadIn(path, env)
  local fn, err
  if setfenv then fn, err = loadfile(path); if fn then setfenv(fn, env) end
  else fn, err = loadfile(path, "t", env) end
  assert(fn, err); return fn()
end
local function fixture(options)
  options = options or {}
  local f = { mode = options.mode or "on", timestamp = 1000, messages = {}, counts = {}, slots = {}, throws = {}, handlers = {}, delivered = {} }
  local env = setmetatable({}, { __index = _G }); f.env = env
  local function count(name) f.counts[name] = (f.counts[name] or 0) + 1 end
  env.os = { time = function() return f.timestamp end }
  env.Comm = { addChatMessage = function(message) f.messages[#f.messages + 1] = message.text end,
    deliverChatMessage = function(message) f.delivered[#f.delivered + 1] = clone(message) end }
  env.DB = { getPath = function(node) return node.path end, getValue = function(node, field, default)
    if type(node) == "table" and default ~= nil then
      if node[field] ~= nil then return node[field] end
      return default
    end
    return field
  end }
  env.ActorManager = { getCreatureNodeName = function(actor) return type(actor) == "table" and actor.id end }
  env.ActorManager5E = { getDefenseValue = function() error("Defense effects must not be evaluated twice") end }
  env.ActionHealthD20 = { apply = function() error("Bridge must never apply HP directly") end }
  env.ArmsCatalog = loadIn("extension/scripts/arms_catalog.lua", env)
  env.ArmsData = loadIn("extension/scripts/arms_data.lua", env)
  env.ArmsData.getMode = function() return f.mode end
  env.ArmsData.weaponFor = function(roll)
    if roll.bSpell == true or roll.bSpell == 1 or (roll.bWeapon ~= true and roll.bWeapon ~= 1) then return nil end
    local label = env.ArmsData.actionLabel(roll)
    if label == "longsword" or label == "mace" then return "bridge_test" end
  end
  env.ArmsData.armorFor = function(actor, ac)
    if actor.noArmor then return nil, "Synthetic missing armor" end
    return { armor = "test", defense = ac - (actor.base or 16), base = actor.base or 16 }
  end
  env.ArmsEngine = loadIn("extension/scripts/arms_engine.lua", env)
  assert(env.ArmsEngine.registerTable("bridge_test", { version = 1, label = "Original adapter fixture", offset = 0,
    provenance = "Synthetic original test data", armors = { test = {
      { min = 0, max = 49, hit = false, quality = 0 },
      { min = 50, max = 99, hit = true, quality = options.quality or 0.25 },
      { min = 100, hit = true, quality = 0.75 },
    } } }))
  f.originalAttack = function(source, target, roll)
    count("attack")
    if options.beforeAttack then options.beforeAttack(source, target, roll) end
    return "attack-native", nil, 7
  end
  env.ActionAttack = { onPreAttackResolve = f.originalAttack,
    getRoll = function(_, action)
      count("attackRoll"); return { bWeapon = action.bWeapon, sLabel = action.label }, nil, "attack-roll-tail"
    end }
  f.originalPreMod = function(source, target, roll)
    count("preMod"); if options.beforeMod then options.beforeMod(source, target, roll) end
    return "mod-native", nil, 8
  end
  f.originalPreResolve = function(source, target, roll)
    count("preResolve"); f.beforeResolveValue = roll.aDice and roll.aDice[1] and roll.aDice[1].result
    if options.beforeResolve then options.beforeResolve(source, target, roll) end
    return "resolve-native", nil, 9
  end
  f.slots["onActionPreModRoll:damage"] = f.originalPreMod
  f.slots["onActionPreResolve:damage"] = f.originalPreResolve
  f.slots["onActionPreResolve:"] = function() count("generic") end
  env.GameManager = {
    getMultiKeyFunction = function(name, key) return f.slots[name .. ":" .. key] end,
    setMultiKeyFunction = function(name, key, fn) f.slots[name .. ":" .. key] = fn end,
  }
  env.GameSystem = { actions = {} }
  f.originalRoll = function(source, targets, roll, multi)
    count("roll"); f.throws[#f.throws + 1] = { source = source, targets = targets, roll = roll, multi = multi }
    return "roll-native", nil, 10
  end
  env.ActionsManager = { roll = f.originalRoll,
    registerResultHandler = function(kind, fn) count("registerResult"); f.handlers[kind] = fn end,
    getResultHandler = function(kind) return f.handlers[kind] end,
    unregisterResultHandler = function(kind) count("unregisterResult"); f.handlers[kind] = nil end,
    createActionMessage = function(source, roll)
      return { type = roll.sType, text = roll.sDesc, dice = roll.aDice, secret = roll.bSecret, tower = roll.bTower }
    end,
    total = function(roll)
    count("total")
    if options.totalError then error("Synthetic total failure") end
    -- Model an engine cache: clearing stale expression/total is necessary.
    if roll.aDice.expr and roll.aDice.total then return roll.aDice.total + roll.nMod end
    local total = roll.nMod
    for _, die in ipairs(roll.aDice) do if not die.dropped then total = total + (die.value or die.result) end end
    return total
  end }
  env.ActionDamageD20 = { getRoll = function(_, action)
    count("damageRoll"); return { bWeapon = action.bWeapon, sLabel = action.label }, nil, "damage-roll-tail"
  end }
  env.CharWeaponManager = {
    buildAttackAction = function(_, node)
      count("buildAttack"); return { bWeapon = true, label = node.label }, nil, "build-attack-tail"
    end,
    buildDamageAction = function(_, node)
      count("buildDamage"); return { bWeapon = true, label = node.label }, nil, "build-damage-tail"
    end,
  }
  if options.noGame then env.GameManager = false end
  if options.noDamage then env.ActionDamageD20 = false end
  if options.noAttack then env.ActionAttack.onPreAttackResolve = nil end
  if options.noIdentity then env.CharWeaponManager = false end
  if options.noOpen then env.ActionsManager.roll = nil end
  if options.noOpenHandler then env.ActionsManager.registerResultHandler = nil end
  if options.noOpenGetter then env.ActionsManager.getResultHandler = nil end
  if options.noOpenChat then env.Comm.deliverChatMessage = nil end
  f.bridge = loadIn("extension/scripts/arms_bridge.lua", env)
  f.bridge.onInit()
  f.source, f.target = { id = "source.1" }, { id = "target.1" }
  function f.attack(overrides, source, target)
    local roll = { nFirstDie = 12, nTotal = 17, nDefenseVal = 18, sResult = "miss", sType = "attack",
      bWeapon = true, sLabel = "Longsword", sDesc = "[ATTACK (M)] Longsword", bSpecial = false,
      aDice = { { type = "d20", result = 12, value = 12 } }, aMessages = { "[COVER +2]", "[MISS]" } }
    for k, v in pairs(overrides or {}) do roll[k] = v end
    env.ActionAttack.onPreAttackResolve(source or f.source, target or f.target, roll, {})
    return roll
  end
  function f.damage(overrides)
    local roll = { sType = "damage", bWeapon = true, sLabel = "Longsword", sDesc = "[DAMAGE] Longsword",
      nMod = 3, nTotal = 15, clauses = {
        { dice = { "d8" }, modifier = 3, dmgtype = "slashing" }, { dice = { "d6" }, modifier = 0, dmgtype = "fire" },
      }, aDice = { { type = "d8", result = 7, value = 7, dmgtype = "slashing" },
        { type = "d6", result = 5, value = 5, dmgtype = "fire" } } }
    for k, v in pairs(overrides or {}) do roll[k] = v end
    return roll
  end
  function f.preMod(roll, source, target)
    return f.slots["onActionPreModRoll:damage"](source or f.source, target or f.target, roll)
  end
  function f.preResolve(roll, source, target)
    return f.slots["onActionPreResolve:damage"](source or f.source, target or f.target, roll)
  end
  function f.landOpen(value, index, overrides)
    local thrown = f.throws[index or #f.throws]
    assert(thrown and thrown.roll.sType == "arms_bridge_open", "Expected a pending open d20 throw")
    local resolved = clone(thrown.roll)
    resolved.aDice = { { type = "d20", result = value, value = value } }
    for k, v in pairs(overrides or {}) do resolved[k] = v end
    f.handlers.arms_bridge_open(thrown.source, nil, resolved)
    return resolved
  end
  return f
end

local f = fixture({ mode = "off" })
local roll = f.attack()
check(roll.sResult == "miss" and roll.sArmsAttackID == nil, "off does not change attack result")
check(equal(roll.aMessages, { "[COVER +2]", "[MISS]" }), "off preserves attack messages")
local damage = f.damage(); local before = clone(damage); f.preMod(damage); f.preResolve(damage)
check(equal(damage, before) and #f.bridge.getPending() == 0, "off leaves complete damage roll unchanged")
check(f.counts.attack == 1 and f.counts.preMod == 1 and f.counts.preResolve == 1, "off still chains native callbacks")

f = fixture({ mode = "compare" }); roll = f.attack(); damage = f.damage(); before = clone(damage)
f.preMod(damage); f.preResolve(damage)
check(roll.sResult == "miss" and roll.sArmsAttackID == nil, "compare observes without replacing native miss")
check(equal(damage, before) and #f.bridge.getPending() == 0, "compare does not stage or modify damage")
check(#f.messages == 1 and f.messages[1]:find("Comparación local", 1, true), "comparison is a local chat message")
local action = f.env.CharWeaponManager.buildAttackAction({}, { path = "weapon.1", label = "Longsword" })
check(action.sArmsWeaponNode == nil, "compare builder does not add metadata")

f = fixture(); check(f.bridge.getCapabilities().ready and f.bridge.getCapabilities().identity, "complete mocked contract is ready")
check(type(f.env.onInit) == "function" and type(f.env.status) == "function", "FG script-scope exports exist")
roll = f.attack()
check(roll.sResult == "hit", "table can turn native miss into hit")
check(roll.nFirstDie == 12 and roll.nTotal == 17 and roll.nDefenseVal == 18, "native dice and effect-adjusted totals stay intact")
check(roll.aMessages[1] == "[COVER +2]" and roll.aMessages[2] == "[HIT]", "only result tags are replaced")
check(roll.bSpecial == false and #f.bridge.getPending() == 1, "native flags stay intact and hit has one context")
local pendingCopy = f.bridge.getPending(); pendingCopy[1].quality = 1
check(f.bridge.getPending()[1].quality == 0.25, "public queue snapshot is not mutable internal state")
damage = f.damage(); before = clone(damage); local rider = damage.aDice[2]
local modA, modB, modC = f.preMod(damage)
check(modA == "mod-native" and modB == nil and modC == 8, "pre-mod callback return tuple preserved")
check(equal(damage.aDice, before.aDice), "staging does not remove, roll or change dice")
check(type(damage.sArmsContextID) == "string" and damage.nArmsBaseDice == 1, "staging adds serializable identity and count")
check(f.bridge.getPending()[1].state == "staged", "context bound once before native critical extras")
local resolveA, resolveB, resolveC = f.preResolve(damage)
check(resolveA == "resolve-native" and resolveB == nil and resolveC == 9, "pre-resolve return tuple preserved")
check(f.beforeResolveValue == 7 and damage.aDice[1].result == 2 and damage.aDice[1].value == 2, "native callback runs before atomic result/value conversion")
check(damage.aDice[2] == rider and rider.result == 5 and damage.nMod == 3, "rider dice and modifiers untouched")
check(equal(damage.clauses, before.clauses) and damage.nTotal == 10, "native clauses preserved and total recomputed")
check(damage.bArmsConverted and #f.bridge.getPending() == 0, "successful conversion consumes context")
check(damage.sArmsOriginalBase == "7" and damage.sArmsResolvedBase == "2", "original and converted base values available for review")
check(damage.sDesc:find("ARMS BASE", 1, true) ~= nil, "changed damage is labelled")
check(f.counts.generic == nil, "wrapper does not call the generic callback a second time")

f = fixture({ beforeAttack = function(_, _, r) r.nTotal = 24 end })
roll = f.attack(); check(f.bridge.getPending()[1].quality == 0.75, "attack conversion observes preceding extension's modifications")
local attackA, attackB, attackC = f.env.ActionAttack.onPreAttackResolve(f.source, f.target, roll, {})
check(attackA == "attack-native" and attackB == nil and attackC == 7, "attack original called once with all return values")
check(#f.bridge.getPending() == 1, "replayed attack marker cannot create second entitlement")

for _, scenario in ipairs({
  { natural = 1, total = 99, ac = 10, native = "fumble", expected = "fumble", pending = 0 },
  { natural = 20, total = 20, ac = 100, native = "crit", expected = "crit", pending = 1 },
  { natural = 19, total = 24, ac = 100, native = "crit", expected = "crit", pending = 1 },
  { natural = 12, total = 17, ac = 30, native = "hit", expected = "miss", pending = 0 },
}) do
  f = fixture(); roll = f.attack({ nFirstDie = scenario.natural, nTotal = scenario.total,
    nDefenseVal = scenario.ac, sResult = scenario.native })
  check(roll.sResult == scenario.expected and #f.bridge.getPending() == scenario.pending, "natural/critical/table precedence preserved")
  if scenario.expected == "crit" then
    if scenario.natural == 20 then
      check(roll.aMessages[#roll.aMessages] == "[ARMS OPEN PENDING]", "natural twenty announces its pending continuation")
      f.landOpen(1)
    else check(roll.aMessages[#roll.aMessages] == "[ARMS CRITICAL NATIVE]", "expanded critical preserves native damage without opening a d20") end
    damage = f.damage(); before = clone(damage); f.preMod(damage)
    check(equal(damage, before) and #f.bridge.getPending() == 0, "critical attack context is consumed without staging damage conversion")
    local extra = { type = "g8", result = 4, value = 4, dmgtype = "slashing,critical" }
    damage.aDice[#damage.aDice + 1] = extra
    damage.clauses[#damage.clauses + 1] = { dice = { "d8" }, modifier = 0, dmgtype = "slashing,critical", bCritical = true }
    damage.bCritical, damage.nTotal = true, 19; before = clone(damage); f.preResolve(damage)
    check(equal(damage, before), "critical damage preserves all native dice, clauses, flags, modifiers and total")
    damage = f.damage(); before = clone(damage); f.preMod(damage); f.preResolve(damage)
    check(equal(damage, before), "later damage cannot reuse the consumed critical attack")
  end
end

-- Critical modifiers may be present at either native damage hook, including
-- when an otherwise normal attack was already associated with the roll.
for _, criticalStage in ipairs({ "preMod", "preResolve" }) do
  f = fixture(); f.attack(); damage = f.damage()
  if criticalStage == "preResolve" then f.preMod(damage) end
  damage.bCritical = "true"; before = clone(damage)
  if criticalStage == "preMod" then f.preMod(damage) end
  f.preResolve(damage)
  check(equal(damage, before) and #f.bridge.getPending() == 0, "native critical flag at " .. criticalStage .. " preserves damage and consumes context")
  damage = f.damage(); before = clone(damage); f.preMod(damage); f.preResolve(damage)
  check(equal(damage, before), "critical fallback at " .. criticalStage .. " cannot leak quality into later damage")
end

-- Open d20 chains use native asynchronous dice, one scalar token per throw.
f = fixture(); roll = f.attack({ nFirstDie = 20, nTotal = 25, sResult = "crit", bSecret = true, bTower = true, sUser = "roller" })
check(#f.throws == 1 and f.throws[1].roll.sType == "arms_bridge_open", "initial natural twenty launches one separate native continuation")
check(equal(f.throws[1].roll.aDice, { "d20" }) and f.throws[1].roll.nMod == 0 and f.throws[1].targets == nil,
  "continuation contains exactly one unmodified untargeted d20")
check(f.throws[1].roll.bSecret and f.throws[1].roll.bTower and f.throws[1].roll.sUser == "roller", "continuation preserves secret, tower and user flags")
check(f.bridge.getPending()[1].state == "opening" and f.bridge.getPending()[1].rollTotal == 20,
  "unfinished opening is visible as a pending chain")
local firstContinuation = f.landOpen(10)
check(#f.throws == 1 and f.bridge.getPending()[1].state == "pending" and f.bridge.getPending()[1].rollTotal == 30,
  "20 plus 10 closes at 30 and does not throw another die")
check(f.bridge.getPending()[1].overflow == 13, "open total contributes to the uncapped attack-table overflow")
check(f.counts.attack == 1 and f.counts.preMod == nil, "continuation never reevaluates attack or damage effects")
check(f.delivered[1].secret and f.delivered[1].tower and f.delivered[1].text:find("20+10 = 30", 1, true),
  "completed chain is reviewable in chat and remains secret")
f.handlers.arms_bridge_open(f.source, nil, clone(firstContinuation))
check(f.bridge.getPending()[1].rollTotal == 30 and #f.delivered == 1, "replaying a completed continuation cannot add its d20 again")

f = fixture(); f.attack({ nFirstDie = 20, nTotal = 25, sResult = "crit" })
local continued = f.landOpen(20)
check(#f.throws == 2 and f.bridge.getPending()[1].rollTotal == 40 and f.bridge.getPending()[1].state == "opening",
  "a continuation twenty adds twenty and opens another native d20")
f.handlers.arms_bridge_open(f.source, nil, clone(continued))
check(#f.throws == 2 and f.bridge.getPending()[1].rollTotal == 40, "old launch token cannot add a repeated twenty")
f.landOpen(10)
check(f.bridge.getPending()[1].rollTotal == 50 and f.bridge.getPending()[1].overflow == 33, "20 plus 20 plus 10 resolves at 50 beyond the former final row")

f = fixture(); f.attack({ nFirstDie = 20, nTotal = 25, sResult = "crit" })
for i = 1, 24 do f.landOpen(20) end
f.landOpen(1)
check(f.bridge.getPending()[1].rollTotal == 501 and f.bridge.getPending()[1].overflow == 484,
  "long open chain has no gameplay ceiling and continuation one adds one instead of fumbling")

f = fixture(); f.attack({ nFirstDie = 17, nTotal = 22, sResult = "hit", aDice = {
  { type = "d20", result = 20, dropped = true }, { type = "d20", result = 17 }, } })
check(#f.throws == 0, "a discarded twenty under disadvantage does not open an attack")
f = fixture(); f.attack({ nFirstDie = 20, nTotal = 25, sResult = "crit", aDice = {
  { type = "d20", result = 20 }, { type = "d20", result = 20, dropped = true }, } })
check(#f.throws == 1 and #f.throws[1].roll.aDice == 1, "advantage opens from only the selected result and does not repeat advantage")

f = fixture({ mode = "compare" }); roll = f.attack({ nFirstDie = 20, nTotal = 25, sResult = "crit" })
check(#f.throws == 0 and #f.bridge.getPending() == 0 and roll.sArmsAttackID == nil, "comparison describes opening without actually rolling or changing damage")

-- Damage must be requested AFTER the chain closes. Early damage stays native
-- and consumes this attack's entitlement rather than applying a partial sum.
f = fixture(); f.attack({ nFirstDie = 20, nTotal = 25, sResult = "crit" })
damage = f.damage(); before = clone(damage); f.preMod(damage); f.preResolve(damage)
check(equal(damage, before) and #f.bridge.getPending() == 0, "early damage stays wholly native and consumes the unfinished opening")
check(f.bridge.status().lastNotice:find("antes de terminar la apertura", 1, true), "early damage explains that the player must wait for the chain to close")
f.landOpen(20, 1)
check(#f.throws == 1 and #f.bridge.getPending() == 0, "a late continuation cannot affect already resolved damage or create another entitlement")

f = fixture(); f.attack({ nFirstDie = 20, nTotal = 25, sResult = "crit" })
check(f.bridge.clearPending() == 1 and #f.throws == 1, "clear removes the opening without throwing or applying any damage")
f.landOpen(10, 1)
check(#f.throws == 1 and #f.bridge.getPending() == 0, "late continuation after clear cannot resurrect cancelled context")

f = fixture(); f.attack({ nFirstDie = 20, nTotal = 25, sResult = "crit" }); f.timestamp = 1121
check(#f.bridge.getPending() == 0 and #f.throws == 1, "unfinished openings expire without an implicit damage action")
f.landOpen(10, 1)
check(#f.bridge.getPending() == 0, "timed out continuation cannot re-create a damage entitlement")

f = fixture(); f.attack({ nFirstDie = 20, nTotal = 25, sResult = "crit" }); f.landOpen(10, 1, { nMod = 2 })
check(#f.bridge.getPending() == 0 and #f.throws == 1, "altered continuation aborts without applying a partial supplement")

f = fixture(); f.attack({ nFirstDie = 20, nTotal = 25, sResult = "crit" })
local forgedOpen = clone(f.throws[1].roll); forgedOpen.aDice = { { type = "d20", result = 20, value = 20 } }
f.handlers.arms_bridge_open({ id = "other.client.actor" }, nil, forgedOpen)
check(#f.throws == 1 and f.bridge.getPending()[1].rollTotal == 20, "an unrelated source cannot advance an open context")
f.landOpen(10, 1)
check(f.bridge.getPending()[1].rollTotal == 30, "rejected foreign continuation does not consume the legitimate launch token")

-- Overflow enters the first typed clause BEFORE native encoding/critical
-- processing. Native critical dice themselves remain fully random and legal.
local criticalTotals = {}
for _, continuation in ipairs({ { 10 }, { 20, 10 }, { 20, 20, 10 } }) do
  f = fixture(); f.attack({ nFirstDie = 20, nTotal = 25, sResult = "crit" })
  for _, value in ipairs(continuation) do f.landOpen(value) end
  local overflow = f.bridge.getPending()[1].overflow
  damage = f.damage(); local originalDice, originalRider = clone(damage.aDice), damage.clauses[2]
  f.preMod(damage)
  local supplement = math.floor(4.5 * overflow / 10)
  check(damage.nMod == 3 + supplement and damage.clauses[1].modifier == 3 + supplement,
    "overflow updates the aggregate and first typed modifier consistently before native encoding")
  check(damage.clauses[1].dmgtype == "slashing" and damage.clauses[2] == originalRider,
    "overflow keeps the base physical type and leaves the fire rider untouched")
  check(equal(damage.aDice, originalDice) and damage.bArmsOverflowApplied and damage.nArmsSupplement == supplement,
    "adding overflow changes no die faces and records the supplement once")
  -- Model the native critical-dice preparation AFTER the pre-mod hook. This is
  -- intentionally a contract model; it is not an installed FG certification.
  damage.bCritical = true
  damage.aDice[#damage.aDice + 1] = { type = "g8", result = 4, value = 4, dmgtype = "slashing,critical" }
  damage.clauses[#damage.clauses + 1] = { dice = { "d8" }, modifier = 0, dmgtype = "slashing,critical" }
  damage.nTotal = f.env.ActionsManager.total(damage)
  before = clone(damage); f.preResolve(damage)
  check(equal(damage, before) and damage.aDice[1].result == 7 and damage.nTotal == 19 + supplement,
    "critical resolution keeps native base, rider and extra critical dice without maximization or duplicate overflow")
  check(#f.bridge.getPending() == 0, "critical overflow consumes the original attack context")
  criticalTotals[#criticalTotals + 1] = damage.nTotal
  before = clone(damage); f.preMod(damage); f.preResolve(damage)
  check(equal(damage, before), "replayed damage never adds its overflow modifier a second time")
end
check(criticalTotals[1] == 24 and criticalTotals[2] == 33 and criticalTotals[3] == 42,
  "20+10, 20+20+10 and 20+20+20+10 produce successively larger actual damage totals")
check(criticalTotals[2] > 2 * 8 + 6 + 3, "open damage can exceed the entire ordinary critical-and-rider maximum")

f = fixture(); f.attack({ nFirstDie = 20, nTotal = 25, sResult = "crit" }); f.landOpen(10)
damage = f.damage({ nMod = 5, clauses = {
  { dice = { "d6", "d6" }, modifier = 5, dmgtype = "slashing,magic" },
  { dice = { "d4" }, modifier = 0, dmgtype = "radiant" },
}, aDice = { { type = "d6", result = 1, value = 1 }, { type = "d6", result = 6, value = 6 },
  { type = "d4", result = 2, value = 2 } } })
f.preMod(damage)
check(damage.nArmsSupplement == 9 and damage.nMod == 14 and damage.clauses[1].modifier == 14,
  "two-die weapon scales overflow from the complete 2d6 mean and adds flat modifiers only once")
check(damage.clauses[1].dmgtype == "slashing,magic" and damage.clauses[2].modifier == 0,
  "supplement preserves magical base tags without attaching them to the rider")
damage.bCritical = true; before = clone(damage); f.preResolve(damage)
check(equal(damage, before) and damage.aDice[1].result == 1 and damage.aDice[2].result == 6,
  "multidie native critical base is not replaced with a quantile or illegal oversized faces")

f = fixture(); f.attack({ nFirstDie = 19, nTotal = 50, sResult = "hit" }); damage = f.damage()
f.preMod(damage); f.preResolve(damage)
check(#f.throws == 0 and damage.nArmsSupplement == 12 and damage.nMod == 15 and damage.nTotal == 26,
  "high non-twenty attack total also grows beyond the final table row")
check(damage.aDice[1].result == 6 and damage.aDice[2].result == 5 and damage.bArmsConverted,
  "ordinary overflow combines the existing base quantile with a separate static supplement")

for _, badModifier in ipairs({ false, math.huge, "3" }) do
  f = fixture(); f.attack({ nFirstDie = 20, nTotal = 25, sResult = "crit" }); f.landOpen(10)
  damage = f.damage(); damage.clauses[1].modifier = badModifier; before = clone(damage)
  f.preMod(damage); f.preResolve(damage)
  check(equal(damage, before) and #f.bridge.getPending() == 0,
    "unverified first-clause modifier cannot receive a partial or wrongly typed supplement")
end

f = fixture(); f.attack({ nFirstDie = 20, nTotal = 25, sResult = "crit" }); f.landOpen(10)
damage = f.damage(); f.env.ArmsEngine.damageOverflow = function() error("Synthetic overflow failure") end
before = clone(damage); f.preMod(damage); f.preResolve(damage)
check(equal(damage, before) and #f.bridge.getPending() == 0, "overflow calculation failure preserves the whole unmodified native damage roll")

f = fixture(); f.attack(); f.attack({ nDefenseVal = 30, sResult = "hit" })
check(#f.bridge.getPending() == 0, "later miss invalidates matching earlier hit")
damage = f.damage(); before = clone(damage); f.preMod(damage); f.preResolve(damage)
check(equal(damage, before), "damage after a miss cannot reuse an earlier hit")

f = fixture(); f.attack(); f.attack()
damage = f.damage(); before = clone(damage); f.preMod(damage); f.preResolve(damage)
check(equal(damage, before) and #f.bridge.getPending() == 0, "ambiguous same-weapon queue rejected and discarded")
check(f.bridge.status().lastNotice:find("Varios ataques", 1, true), "ambiguity has a useful local explanation")

f = fixture(); f.attack(); f.attack({ sLabel = "Mace", nTotal = 24 })
local maceDamage = f.damage({ sLabel = "Mace" }); f.preMod(maceDamage); f.preResolve(maceDamage)
damage = f.damage(); f.preMod(damage); f.preResolve(damage)
check(maceDamage.aDice[1].result == 6 and damage.aDice[1].result == 2, "different weapons can resolve in reverse order without quality mixing")

f = fixture(); f.attack({ sArmsWeaponNode = "weapon.1", sArmsHands = "1h" });
f.attack({ sArmsWeaponNode = "weapon.2", sArmsHands = "2h", nTotal = 24 })
damage = f.damage({ sArmsWeaponNode = "weapon.2", sLabel = "Longsword (2H)" }); f.preMod(damage); f.preResolve(damage)
check(damage.aDice[1].result == 6 and #f.bridge.getPending() == 1, "node identity separates equally named weapons")
damage = f.damage({ sArmsWeaponNode = "weapon.1", sLabel = "Longsword (OH)" }); f.preMod(damage); f.preResolve(damage)
check(damage.aDice[1].result == 2, "native OH label matches the captured one-handed weapon identity")

f = fixture(); f.attack({ sLabel = "Longsword +1", sArmsHands = "2h" })
damage = f.damage({ sLabel = "Longsword (2H) +1" }); f.preMod(damage); f.preResolve(damage)
check(damage.aDice[1].result == 2, "label fallback uses real ArmsData normalization")
f = fixture(); f.attack({ bWeapon = "1" })
damage = f.damage({ bWeapon = "true" }); f.preMod(damage); f.preResolve(damage)
check(damage.bArmsConverted, "serialized native boolean flags are accepted")

f = fixture(); f.attack(); local otherSource, otherTarget = { id = "source.2" }, { id = "target.2" }
damage = f.damage(); before = clone(damage); f.preMod(damage, otherSource); f.preResolve(damage, otherSource)
check(equal(damage, before) and #f.bridge.getPending() == 1, "source actor must match")
damage = f.damage(); before = clone(damage); f.preMod(damage, nil, otherTarget); f.preResolve(damage, nil, otherTarget)
check(equal(damage, before) and #f.bridge.getPending() == 1, "target actor must match")
damage = f.damage(); f.preMod(damage); f.preResolve(damage)
check(damage.bArmsConverted, "unrelated damage does not steal the correct pending attack")

f = fixture(); f.attack(); f.attack(nil, nil, { id = "target.2" }); f.attack({ sLabel = "Mace" })
damage = f.damage(); before = clone(damage)
f.slots["onActionPreModRoll:damage"](f.source, nil, damage)
f.preResolve(damage)
check(equal(damage, before), "multi-target modifier call cannot pick a last target")
check(#f.bridge.getPending() == 1 and f.bridge.getPending()[1].label == "mace", "multi-target fallback invalidates only matching weapon contexts")

f = fixture(); local node = { path = "charsheet.1.weaponlist.1", label = "Longsword" }
local a, b, c = f.env.CharWeaponManager.buildAttackAction({}, node)
check(a.sArmsWeaponNode == node.path and b == nil and c == "build-attack-tail", "buildAttack action metadata and returns preserved")
local r, _, tail = f.env.ActionAttack.getRoll(f.source, a)
check(r.sArmsWeaponNode == node.path and tail == "attack-roll-tail", "attack getRoll propagates scalar weapon path")
a, b, c = f.env.CharWeaponManager.buildDamageAction({}, node)
check(a.sArmsWeaponNode == node.path and b == nil and c == "build-damage-tail", "buildDamage action metadata and returns preserved")
r, _, tail = f.env.ActionDamageD20.getRoll(f.source, a)
check(r.sArmsWeaponNode == node.path and tail == "damage-roll-tail", "damage getRoll propagates scalar weapon path")
check(f.counts.buildAttack == 1 and f.counts.buildDamage == 1 and f.counts.attackRoll == 1 and f.counts.damageRoll == 1, "identity wrappers call each native function once")

f = fixture({ quality = 1 / 3 }); f.attack(); damage = f.damage(); f.preMod(damage)
local serialized = clone(damage)
serialized.nArmsBaseDice = tostring(serialized.nArmsBaseDice)
serialized.nArmsQuality = string.format("%.14g", serialized.nArmsQuality)
f.preResolve(serialized)
check(serialized.bArmsConverted, "scalar round trip tolerates Lua's shortened numeric string formatting")
local replay = clone(serialized); before = clone(replay); f.preResolve(replay)
check(equal(replay, before), "converted damage replay has no second conversion")
replay = clone(damage); before = clone(replay); f.preResolve(replay)
check(equal(replay, before), "same context token cannot convert another roll after consumption")

f = fixture(); f.attack(); damage = f.damage(); f.preMod(damage)
local forged = clone(damage); forged.sArmsTargetID = "target.2"; before = clone(forged); f.preResolve(forged)
check(equal(forged, before) and #f.bridge.getPending() == 0, "changed serialized target invalidates staged context without changing dice")
f = fixture(); f.attack(); damage = f.damage(); f.preMod(damage); before = clone(damage)
f.preMod(damage); f.preResolve(damage)
check(equal(damage, before) and #f.bridge.getPending() == 0, "re-entering modifier pipeline invalidates replayed context")

for _, invalid in ipairs({
  { nFirstDie = "12" }, { nFirstDie = 0 }, { nTotal = math.huge }, { nDefenseVal = false },
  { sResult = "unknown" }, { aMessages = false }, { sLabel = "Unknown weapon" },
  { bSpell = true }, { bSpell = "1" },
}) do
  f = fixture(); roll = f.attack(invalid)
  check(roll.sArmsAttackID == nil and #f.bridge.getPending() == 0, "malformed or excluded attack uses native result")
end
f = fixture(); f.target.noArmor = true; roll = f.attack()
check(roll.sResult == "miss" and #f.bridge.getPending() == 0, "unknown armor cannot silently choose a profile")

for _, corrupt in ipairs({
  function(d) d.clauses = {} end,
  function(d) d.clauses[1].dice = { "2d8" } end,
  function(d) d.aDice[1].type = "-d8" end,
  function(d) d.aDice[1].dropped = true end,
  function(d) d.aDice = {} end,
}) do
  f = fixture(); f.attack(); damage = f.damage(); corrupt(damage); before = clone(damage)
  f.preMod(damage); f.preResolve(damage)
  check(equal(damage, before) and #f.bridge.getPending() == 0, "unsupported base dice consume pending context with native fallback")
end

for _, corrupt in ipairs({
  function(d) d.aDice[1].type = "d6" end,
  function(d) d.aDice[1].result = nil end,
  function(d) d.aDice[1].dropped = true end,
  function(d) d.aDice.expr = "1d8kh1+1d6" end,
  function(d) d.nMod = math.huge end,
}) do
  f = fixture(); f.attack(); damage = f.damage(); f.preMod(damage); corrupt(damage); before = clone(damage)
  f.preResolve(damage)
  check(equal(damage, before) and #f.bridge.getPending() == 0, "changed or unsupported resolved dice remain wholly native")
end
f = fixture(); f.attack(); damage = f.damage(); f.preMod(damage)
damage.aDice[1].type = "g8"; damage.aDice.expr = "1d8 + 1d6"; damage.aDice.total = 999
f.preResolve(damage)
check(damage.bArmsConverted and damage.nTotal == 10, "native colour change and matching additive expression safely recompute cached totals")
check(damage.aDice.expr == nil and damage.aDice.total == nil, "stale expression caches cleared")

f = fixture({ totalError = true }); f.attack(); damage = f.damage(); f.preMod(damage); before = clone(damage)
f.preResolve(damage)
check(equal(damage, before) and #f.bridge.getPending() == 0, "calculation error never partially changes native damage")
f = fixture(); f.attack(); damage = f.damage(); f.preMod(damage)
f.env.ArmsEngine.damageDice = function() error("Synthetic engine failure") end
before = clone(damage); f.preResolve(damage)
check(equal(damage, before) and #f.bridge.getPending() == 0, "engine error preserves complete native roll")

for _, missing in ipairs({ "noGame", "noDamage", "noAttack", "noOpen", "noOpenHandler", "noOpenGetter", "noOpenChat" }) do
  f = fixture({ [missing] = true })
  check(not f.bridge.getCapabilities().ready and f.bridge.status().effectiveMode == "compare", "missing API forces comparison without hard crash")
  if missing ~= "noAttack" then roll = f.attack(); check(roll.sResult == "miss" and #f.bridge.getPending() == 0, "missing damage API cannot modify attacks") end
end
f = fixture({ noIdentity = true }); f.attack(); damage = f.damage(); f.preMod(damage); f.preResolve(damage)
check(f.bridge.getCapabilities().ready and not f.bridge.getCapabilities().identity and damage.bArmsConverted, "optional identity APIs fall back to normalized labels")

f = fixture(); f.attack(); damage = f.damage(); f.preMod(damage); before = clone(damage); f.mode = "compare"
f.preResolve(damage)
check(equal(damage, before) and #f.bridge.getPending() == 1, "compare callback itself does not mutate staged state")
check(f.bridge.clearPending() == 1 and #f.bridge.getPending() == 0, "explicit mode-change cleanup clears staged state")

f = fixture(); f.attack(); f.bridge.bypassNext(); damage = f.damage(); before = clone(damage)
f.preMod(damage); f.preResolve(damage)
check(equal(damage, before) and #f.bridge.getPending() == 0, "one-shot bypass preserves native damage and removes pending context")
f.attack(); damage = f.damage(); f.preMod(damage); f.preResolve(damage)
check(damage.bArmsConverted, "bypass is consumed exactly once")

f = fixture(); f.attack(); f.timestamp = 1121
check(#f.bridge.getPending() == 0, "pending contexts expire after 120 seconds")
damage = f.damage(); before = clone(damage); f.preMod(damage); f.preResolve(damage)
check(equal(damage, before), "expired attacks cannot affect later manual damage")
f = fixture(); f.attack(); damage = f.damage(); f.preMod(damage); f.timestamp = 1121; before = clone(damage)
f.preResolve(damage)
check(equal(damage, before) and #f.bridge.getPending() == 0, "staged contexts also expire")
f = fixture()
for i = 1, 140 do f.attack(nil, nil, { id = "target." .. i }) end
check(#f.bridge.getPending() <= 128, "memory is bounded even without advancing the clock")

f = fixture(); local attackHook, damageHook = f.env.ActionAttack.onPreAttackResolve, f.slots["onActionPreResolve:damage"]
f.bridge.onInit(); f.attack(); damage = f.damage(); f.preMod(damage); f.preResolve(damage)
check(f.env.ActionAttack.onPreAttackResolve == attackHook and f.slots["onActionPreResolve:damage"] == damageHook, "initialization is idempotent")
check(f.counts.attack == 1 and f.counts.preMod == 1 and f.counts.preResolve == 1, "repeated init never doubles callbacks")
f.bridge.onClose()
check(f.env.ActionAttack.onPreAttackResolve == f.originalAttack and f.slots["onActionPreResolve:damage"] == f.originalPreResolve, "close restores owned hooks")
check(f.slots["onActionPreModRoll:damage"] == f.originalPreMod and #f.bridge.getPending() == 0, "close clears pending and restores pre-mod hook")
check(f.handlers.arms_bridge_open == nil and f.env.GameSystem.actions.arms_bridge_open == nil,
  "close unregisters the dedicated open action and removes its owned action definition")
f.bridge.onInit(); check(f.bridge.getCapabilities().ready, "explicit reinitialization reinstalls hooks")
local laterExtension = function() end; f.env.ActionAttack.onPreAttackResolve = laterExtension
f.slots["onActionPreResolve:damage"] = laterExtension; f.bridge.onClose()
check(f.env.ActionAttack.onPreAttackResolve == laterExtension and f.slots["onActionPreResolve:damage"] == laterExtension, "close never overwrites a later extension's hooks")

f = fixture(); local ownedDefinition = f.env.GameSystem.actions.arms_bridge_open
f.handlers.arms_bridge_open = laterExtension
check(not f.bridge.getCapabilities().ready and f.bridge.status().effectiveMode == "compare",
  "a replaced open-result callback disables conversion instead of silently sending continuations elsewhere")
f.bridge.onClose()
check(f.handlers.arms_bridge_open == laterExtension and f.env.GameSystem.actions.arms_bridge_open == ownedDefinition,
  "close preserves a later result handler and the action definition it still uses")

f = fixture(); f.attack({ nFirstDie = 19, nTotal = 50, sResult = "hit" }); damage = f.damage(); f.preMod(damage)
local preparedDamage = clone(damage); damage.aDice[1].type = "d6"; before = clone(damage); f.preResolve(damage)
check(equal(damage, before) and damage.nMod == preparedDamage.nMod and damage.nArmsSupplement == 12,
  "late quality failure preserves the already encoded overflow instead of attempting an unsafe rollback")
check(f.bridge.status().lastNotice:find("incluido el suplemento de tabla +12", 1, true),
  "late quality failure explicitly discloses that the prepared overflow remains part of the damage")

-- Typed components: all thirteen D&D damage types are recognized, while only
-- the actual physical weapon clause supplies quantiles and overflow scaling.
local function componentDamage(fixtureValue, element, elementFirst)
  local physicalClause = { dice = { "d8" }, modifier = 3, dmgtype = "slashing,magic" }
  local riderClause = { dice = { "d4" }, modifier = 0, dmgtype = element }
  local physicalDie = { type = "d8", result = 7, value = 7, dmgtype = "slashing,magic" }
  local riderDie = { type = "d4", result = 3, value = 3, dmgtype = element }
  return fixtureValue.damage({ nMod = 3, nTotal = 13,
    clauses = elementFirst and { riderClause, physicalClause } or { physicalClause, riderClause },
    aDice = elementFirst and { riderDie, physicalDie } or { physicalDie, riderDie } })
end
for _, element in ipairs({ "acid", "cold", "fire", "force", "lightning", "necrotic", "poison", "psychic", "radiant", "thunder" }) do
  for _, elementFirst in ipairs({ false, true }) do
    f = fixture(); f.attack(); damage = componentDamage(f, element, elementFirst)
    local physicalIndex, riderIndex = elementFirst and 2 or 1, elementFirst and 1 or 2
    local riderDie, riderClause = damage.aDice[riderIndex], damage.clauses[riderIndex]
    f.preMod(damage)
    check(damage.nArmsBaseStart == physicalIndex and damage.nArmsBaseClause == physicalIndex
      and damage.sArmsBaseDice == "d8" and damage.nArmsBaseDice == 1,
      "physical clause is located independently of the " .. element .. " component's order")
    f.preResolve(damage)
    check(damage.bArmsConverted and damage.aDice[physicalIndex].result == 2 and damage.nTotal == 8,
      "only physical d8 follows attack quality; the " .. element .. " d4 remains a native roll")
    check(damage.aDice[riderIndex] == riderDie and riderDie.result == 3 and damage.clauses[riderIndex] == riderClause
      and riderClause.dmgtype == element and riderClause.modifier == 0,
      "the " .. element .. " component retains its dice, modifier and native damage type")
  end
end

-- This deliberately independent model aggregates typed damage, then applies a
-- target multiplier. It verifies that our output retains the information a
-- native ruleset needs; it does NOT certify FG's uninstalled resistance code.
local function typedDamageModel(r, factors)
  local byType, dieIndex = {}, 1
  local known = { acid = true, bludgeoning = true, cold = true, fire = true, force = true,
    lightning = true, necrotic = true, piercing = true, poison = true, psychic = true,
    radiant = true, slashing = true, thunder = true }
  for _, clause in ipairs(r.clauses) do
    local kind
    for token in clause.dmgtype:gmatch("[^,]+") do if known[token] then kind = token; break end end
    assert(kind, "Typed model requires one recognized damage type per clause")
    local amount = clause.modifier
    for _ in ipairs(clause.dice) do
      amount = amount + (r.aDice[dieIndex].value or r.aDice[dieIndex].result); dieIndex = dieIndex + 1
    end
    byType[kind] = (byType[kind] or 0) + amount
  end
  local adjusted = 0
  for kind, amount in pairs(byType) do
    local factor = factors and factors[kind]
    if factor == nil then factor = 1 end
    adjusted = adjusted + math.floor(amount * factor)
  end
  return adjusted, byType
end

f = fixture(); f.attack({ nFirstDie = 19, nTotal = 50, sResult = "hit" })
damage = componentDamage(f, "acid", true); local untouchedAcid = damage.clauses[1]
f.preMod(damage)
check(damage.nArmsSupplement == 12 and damage.clauses[2].modifier == 15 and damage.nMod == 15,
  "overflow mean comes from physical d8 alone even when an acid d4 appears first")
check(damage.clauses[1] == untouchedAcid and damage.clauses[1].modifier == 0 and damage.clauses[2].dmgtype == "slashing,magic",
  "overflow enters the physical clause, never the preceding acid clause")
f.preResolve(damage)
local modeledTotal, modeledTypes = typedDamageModel(damage)
check(damage.nTotal == 24 and modeledTotal == 24 and modeledTypes.slashing == 21 and modeledTypes.acid == 3,
  "dice total and independently reconstructed typed components agree after physical overflow")
check(typedDamageModel(damage, { acid = 0.5 }) == 22 and typedDamageModel(damage, { acid = 0 }) == 21,
  "the preserved acid component can independently receive resistance or immunity")
check(typedDamageModel(damage, { slashing = 0.5 }) == 13 and typedDamageModel(damage, { slashing = 2 }) == 45,
  "physical resistance or vulnerability affects the physical supplement and leaves acid separate")

f = fixture(); f.attack({ nFirstDie = 20, nTotal = 25, sResult = "crit" }); f.landOpen(10)
damage = componentDamage(f, "necrotic", true); f.preMod(damage)
check(damage.nArmsSupplement == 5 and damage.clauses[2].modifier == 8 and damage.clauses[1].modifier == 0,
  "open critical overflow uses physical mean only, without the separate necrotic d4")
-- Simulate native critical doubling of EACH component after our pre-mod hook.
damage.bCritical = true
damage.clauses[#damage.clauses + 1] = { dice = { "d4" }, modifier = 0, dmgtype = "necrotic,critical" }
damage.aDice[#damage.aDice + 1] = { type = "g4", result = 2, value = 2, dmgtype = "necrotic,critical" }
damage.clauses[#damage.clauses + 1] = { dice = { "d8" }, modifier = 0, dmgtype = "slashing,magic,critical" }
damage.aDice[#damage.aDice + 1] = { type = "g8", result = 4, value = 4, dmgtype = "slashing,magic,critical" }
damage.nTotal = f.env.ActionsManager.total(damage); before = clone(damage); f.preResolve(damage)
check(equal(damage, before) and damage.nTotal == 24 and damage.aDice[1].result == 3 and damage.aDice[3].result == 2,
  "native critical doubles the necrotic component's dice without quantile conversion or overflow on that component")
modeledTotal, modeledTypes = typedDamageModel(damage)
check(modeledTotal == 24 and modeledTypes.slashing == 19 and modeledTypes.necrotic == 5
  and typedDamageModel(damage, { necrotic = 0.5 }) == 21,
  "both native necrotic critical dice remain in the same independently resistible component")

for _, kind in ipairs({ "bludgeoning", "piercing", "slashing" }) do
  f = fixture(); f.attack({ sLabel = "Mace", sArmsGroup = "blunted" })
  damage = f.damage({ sLabel = "Mace", sArmsGroup = "blunted", clauses = {
    { dice = { "d8" }, modifier = 3, dmgtype = kind .. ",silver,adamantine" },
  }, aDice = { { type = "d8", result = 7, value = 7, dmgtype = kind .. ",silver,adamantine" } } })
  f.preMod(damage); f.preResolve(damage)
  check(damage.bArmsConverted and damage.aDice[1].result == 2 and damage.clauses[1].dmgtype == kind .. ",silver,adamantine",
    "physical type " .. kind .. " comes from its clause rather than from the blunted table group")
end

for _, mixed in ipairs({ "slashing,acid", "piercing,necrotic", "bludgeoning,fire", "slashing,piercing", "slashing,unknown-energy" }) do
  f = fixture(); f.attack({ nFirstDie = 19, nTotal = 50, sResult = "hit" })
  damage = f.damage({ clauses = { { dice = { "d8", "d4" }, modifier = 3, dmgtype = mixed } },
    aDice = { { type = "d8", result = 7 }, { type = "d4", result = 3 } } })
  before = clone(damage); f.preMod(damage); f.preResolve(damage)
  check(equal(damage, before) and #f.bridge.getPending() == 0,
    "an inseparable or unknown physical mixture gets neither a quantile nor overflow")
end
for _, onlyType in ipairs({ "acid", "necrotic", "force", "unknown-energy" }) do
  f = fixture(); f.attack({ nFirstDie = 19, nTotal = 50, sResult = "hit" })
  damage = f.damage({ clauses = { { dice = { "d8" }, modifier = 3, dmgtype = onlyType } },
    aDice = { { type = "d8", result = 7, value = 7, dmgtype = onlyType } } })
  before = clone(damage); f.preMod(damage); f.preResolve(damage)
  check(equal(damage, before) and #f.bridge.getPending() == 0, "damage without a physical base remains wholly native")
end

for _, extraTag in ipairs({ "critical", "precision" }) do
  f = fixture(); f.attack(); damage = f.damage({ clauses = {
    { dice = { "d6" }, modifier = 0, dmgtype = "slashing," .. extraTag },
    { dice = { "d8" }, modifier = 3, dmgtype = "slashing" },
  }, aDice = { { type = "d6", result = 5, value = 5, dmgtype = "slashing," .. extraTag },
    { type = "d8", result = 7, value = 7, dmgtype = "slashing" } } })
  f.preMod(damage); f.preResolve(damage)
  check(damage.bArmsConverted and damage.nArmsBaseStart == 2 and damage.aDice[1].result == 5 and damage.aDice[2].result == 2,
    "an explicitly marked " .. extraTag .. " component cannot be mistaken for the base physical weapon pool")
end

f = fixture(); f.attack(); damage = componentDamage(f, "acid", true); f.preMod(damage)
damage.nArmsBaseStart = 1; before = clone(damage); f.preResolve(damage)
check(equal(damage, before), "forged physical offset cannot redirect the quantile into the acid die")
f = fixture(); f.attack(); damage = componentDamage(f, "acid", true); f.preMod(damage)
damage.clauses[1], damage.clauses[2] = damage.clauses[2], damage.clauses[1]
damage.aDice[1], damage.aDice[2] = damage.aDice[2], damage.aDice[1]
before = clone(damage); f.preResolve(damage)
check(equal(damage, before), "component reordering after staging cannot silently retarget the physical conversion")

-- One-handed and two-handed uses of a versatile weapon keep separate contexts.
f = fixture(); f.attack({ sArmsWeaponNode = "weapon.1", sArmsHands = "1h" })
f.attack({ sArmsWeaponNode = "weapon.1", sArmsHands = "2h", nTotal = 24 })
damage = f.damage({ sArmsWeaponNode = "weapon.1", sArmsHands = "2h" }); f.preMod(damage); f.preResolve(damage)
check(damage.aDice[1].result == 6 and #f.bridge.getPending() == 1, "two-handed damage consumes only the two-handed attack context")
damage = f.damage({ sArmsWeaponNode = "weapon.1", sArmsHands = "1h" }); f.preMod(damage); f.preResolve(damage)
check(damage.aDice[1].result == 2 and #f.bridge.getPending() == 0, "one-handed damage retains its own independently captured attack quality")
f = fixture(); f.attack({ sArmsHands = "unknown" }); damage = f.damage({ sArmsHands = "2h" }); before = clone(damage)
f.preMod(damage); f.preResolve(damage)
check(equal(damage, before) and #f.bridge.getPending() == 1, "unknown usage is not silently equated with a later two-handed action")

for handling, expectedHands in pairs({ [0] = "1h", [1] = "2h", [2] = "1h" }) do
  f = fixture(); local weaponNode = { path = "weapon.handling", label = "Longsword", handling = handling }
  local builtAttack = f.env.CharWeaponManager.buildAttackAction({}, weaponNode)
  local builtDamage = f.env.CharWeaponManager.buildDamageAction({}, weaponNode)
  local capturedAttack = f.env.ActionAttack.getRoll(f.source, builtAttack)
  local capturedDamage = f.env.ActionDamageD20.getRoll(f.source, builtDamage)
  check(capturedAttack.sArmsHands == expectedHands and capturedDamage.sArmsHands == expectedHands,
    "native handling " .. handling .. " is captured identically for attack and damage")
  check(capturedAttack.sArmsCategory == "martial" and capturedDamage.sArmsGroup == "bladed",
    "catalog category and campaign group survive action-to-roll propagation")
end

print(string.format("Arms bridge: %d checks passed (mocked FG contract; no live-runtime certification).", checks))
