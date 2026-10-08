local engine = dofile("extension/scripts/arms_engine.lua")
local checks = 0

local function check(condition, message)
  checks = checks + 1
  assert(condition, message or ("check " .. checks .. " failed"))
end

local function sum(values)
  local total = 0
  for _, value in ipairs(values) do total = total + value end
  return total
end

local function attack(overrides)
  local opts = { natural = 12, attack_bonus = 5, defense = 0, weapon = "sword", armor = "unarmored" }
  for key, value in pairs(overrides or {}) do opts[key] = value end
  return engine.resolve(opts)
end

local function fixture()
  return {
    version = 1, label = "Synthetic test fixture", provenance = "Original test data", offset = 0,
    armors = {
      test = {
        { min = 0, max = 49, hit = false, quality = 0 },
        { min = 50, max = 99, hit = true, quality = 0.25 },
        { min = 100, hit = true, quality = 0.75 },
      },
    },
  }
end

check(engine.getVersion() == "0.3.1", "version")
check(type(resolve) == "function", "functions must also be exported to the FG script scope")
local ids = engine.listTables()
check(table.concat(ids, ",") == "axes,bladed,blunted,bows,crossbows,exotic,firearms,polearms", "eight canonical default tables without duplicate aliases")
check(table.concat(engine.getDefaultTableIds(), ",") == "blunted,bladed,axes,polearms,bows,crossbows,exotic,firearms",
  "default family order follows the requested classification")
local families = engine.getFamilies()
local labels = {}
for _, family in ipairs(families) do labels[#labels + 1] = family.label end
check(table.concat(labels, ",") == "Blunted weapons,Bladed weapons,Axes,Pole arms,Bows,Crossbows,Exotic,Firearms",
  "the eight family labels remain exact")
families[1].id, families[1].aliases[1] = "changed", "changed"
local defaultIds = engine.getDefaultTableIds()
defaultIds[1] = "changed"
check(engine.getFamilies()[1].id == "blunted" and engine.getFamilies()[1].aliases[1] == "mace"
  and engine.getDefaultTableIds()[1] == "blunted", "public family metadata is returned as independent copies")
local aliases = { mace = "blunted", sword = "bladed", axe = "axes", spear = "polearms", bow = "bows" }
for alias, canonical in pairs(aliases) do
  check(engine.canonicalTableId(alias) == canonical and engine.canonicalTableId(canonical) == canonical,
    "legacy aliases resolve to one canonical family")
  local resolved = attack({ weapon = alias })
  check(resolved.table_id == canonical and resolved.requested_table_id == alias,
    "attack results retain requested identity while using the canonical registry")
  check(engine.getTable(alias).label == engine.getTable(canonical).label, "getTable accepts a legacy family name")
end
check(engine.canonicalTableId("sword_1h") == "sword_1h" and engine.canonicalTableId("bladed_2h") == "bladed_2h",
  "legacy aliases do not rewrite custom prefixes or handedness variants")
check(engine.canonicalTableId("campaign_custom") == "campaign_custom" and engine.canonicalTableId(nil) == nil,
  "custom identifiers remain available and missing identifiers remain missing")
local armorIds = { "unarmored", "leather", "mail", "plate", "natural_hide", "natural_scales", "natural_shell" }
for _, id in ipairs(ids) do
  local definition = engine.getTable(id)
  check(engine.validateTable(definition), "all demo definitions validate")
  check(definition.provenance:find("not Iron Crown Enterprises", 1, true) ~= nil, "explicit original-data provenance")
  for _, armor in ipairs(armorIds) do
    for natural = 1, 20 do
      local result = attack({ weapon = id, armor = armor, natural = natural })
      check(result and result.quality >= 0 and result.quality <= 1, "all ordinary demo lookups resolve")
    end
  end
end

-- Seed equality is intentional, and does not imply automatic assignment from
-- an NPC's AC or that an unarmored creature has tough hide. The copied columns
-- can later be replaced independently through a full custom table definition.
for _, id in ipairs(ids) do
  local definition = engine.getTable(id)
  for natural, seed in pairs({ natural_hide = "leather", natural_scales = "mail", natural_shell = "plate" }) do
    check(definition.armors[natural] ~= definition.armors[seed]
      and definition.armors[natural][2] ~= definition.armors[seed][2], "natural profile seeds have independent row objects")
    for face = 1, 20 do
      local naturalResult = attack({ weapon = id, armor = natural, natural = face })
      local seedResult = attack({ weapon = id, armor = seed, natural = face })
      check(naturalResult.hit == seedResult.hit and naturalResult.quality == seedResult.quality
        and naturalResult.overflow == seedResult.overflow, "natural demo profiles transparently reproduce their declared seeds")
    end
  end
end
check(attack({natural = 5, armor = "unarmored"}).hit
  and not attack({natural = 5, armor = "natural_hide"}).hit, "no protection and tough hide are mechanically distinct profiles")
check(attack({armor = "noarmour"}) == nil and attack({armor = "hide"}) == nil,
  "the engine does not silently reinterpret ambiguous armor names")
for _, copiedFamily in ipairs({"crossbows", "firearms", "exotic"}) do
  local seedFamily = copiedFamily == "exotic" and "bladed" or "bows"
  for _, armor in ipairs(armorIds) do
    local result = attack({weapon = copiedFamily, armor = armor, natural = 20, open_roll = {20,20,10}})
    local seeded = attack({weapon = seedFamily, armor = armor, natural = 20, open_roll = {20,20,10}})
    check(result.quality == seeded.quality and result.overflow == seeded.overflow,
      "new families use their declared demo seed without arbitrary penetration bonuses")
  end
end
local ordinary = attack({weapon = "bladed"})
local attributed = attack({weapon = "bladed", category = "martial", hands = 2})
check(ordinary.index == attributed.index and ordinary.quality == attributed.quality and ordinary.overflow == attributed.overflow,
  "category and handedness metadata do not introduce hidden attack or damage bonuses")

local r = attack({ natural = 1, attack_bonus = 100, crit = true, force_hit = true })
check(not r.hit and not r.critical and r.quality == 0, "natural one overrides a native/forced hit")
r = attack({ natural = 20, defense = 100, force_miss = true })
check(r.hit and r.critical and r.quality == 1, "natural twenty overrides forced miss and high defense")
check(r.needs_open and r.roll_total == 20 and r.open_count == 1 and r.overflow == 0,
  "an uncontinued natural twenty is pending and has no damage supplement")
r = attack({ natural = 19, defense = 100, crit = true })
check(r.hit and r.critical and r.reason == "native_critical", "expanded native critical must still hit")
r = attack({ crit = true, force_hit = true, force_miss = true })
check(not r.hit and not r.critical, "forced miss wins other explicit flags except natural twenty")
r = attack({ natural = 2, defense = 100, force_hit = true })
check(r.hit and not r.critical and r.quality == 0.5, "forced ordinary hit uses a neutral quality on miss rows")
r = attack({ natural = 2, defense = 100 })
check(not r.hit and r.clamped and r.index == 0 and r.raw_index == -465, "negative index clamps to safe miss row")
r = attack({ attack_bonus = 5.1 })
check(r.raw_index == 85.5 and r.index == 85 and r.quantized, "fractional index is explicit and rounds down")
check(attack({ natural = 0 }) == nil, "reject natural zero")
check(attack({ natural = 20.5 }) == nil, "reject fractional natural die")
check(attack({ attack_bonus = 0/0 }) == nil, "reject NaN modifier")
check(attack({ defense = math.huge }) == nil, "reject infinite defense")
check(attack({ weapon = "missing" }) == nil, "unknown weapon fails closed")
check(attack({ armor = "missing" }) == nil, "unknown armor fails closed")
check(attack({ crit = "true" }) == nil, "boolean flags are not strings")

-- Open attacks keep the selected initial natural die separate from their
-- cumulative score. Only the initial die controls automatic miss/critical.
r = attack({ natural = 20, open_roll = {20, 10}, armor = "plate" })
check(r.roll_total == 30 and r.open_count == 1 and not r.needs_open, "20 plus 10 resolves as 30")
check(r.hit and r.critical and r.natural == 20 and r.index == 175,
  "open total feeds the table while a single native critical is retained")
check(r.quality == 1 and r.overflow == 9 and r.overflow_start == 130,
  "terminal-row excess is separate from the bounded percentile")
r = attack({ natural = 20, open_roll = {20, 20, 10}, armor = "plate" })
check(r.roll_total == 50 and r.open_count == 2 and not r.needs_open and r.index == 275,
  "every subsequent twenty adds another continuation without resetting the score")
check(r.overflow == 29 and r.critical, "a second twenty adds excess, not a second kind of critical")
r = attack({ natural = 20, open_roll = {20, 1}, armor = "plate" })
check(r.roll_total == 21 and not r.needs_open and r.hit and r.critical,
  "continuation one adds one and does not become a fumble")
check(r.overflow == 0, "no extra damage at the terminal interval start")
r = attack({ natural = 20, open_roll = {20, 20}, armor = "plate" })
check(r.roll_total == 40 and r.open_count == 2 and r.needs_open and r.overflow == 0,
  "a chain ending in twenty remains pending even above the last interval")
r = attack({ natural = 19, crit = true, open_roll = {19} })
check(r.critical and not r.needs_open and r.open_count == 0,
  "expanded native critical ranges do not open non-twenties")
r = attack({ natural = 1, attack_bonus = 1000, open_roll = {1} })
check(not r.hit and not r.needs_open and r.overflow == 0, "automatic misses cannot gain overflow damage")
r = attack({ natural = 19, attack_bonus = 20 })
check(r.hit and not r.critical and not r.needs_open and r.overflow == 15,
  "a high ordinary attack can exceed the table without a separate damage ceiling")
local openInput = {20, 10}
r = attack({ natural = 20, open_roll = openInput })
openInput[2] = 1
check(r.open_roll[2] == 10 and r.roll_total == 30, "resolved sequence does not retain a mutable input alias")
for _, badRolls in ipairs({
  {}, {19, 10}, {20, 0}, {20, 21}, {20, 10.5}, {20, 10, 5},
  {20, "10"}, {20, 0/0}, {20, math.huge}, {[1] = 20, [3] = 10},
  {[1] = 20, x = 10}, setmetatable({20, 10}, {}),
}) do
  local invalid, message = attack({ natural = 20, open_roll = badRolls })
  check(invalid == nil and type(message) == "string", "invalid open sequence fails with an explanation")
end
check(attack({ natural = 19, open_roll = {19, 20} }) == nil, "a non-twenty cannot acquire a continuation")
check(attack({ natural = 20, open_roll = "20+10" }) == nil, "engine requires structured open rolls")
local longRoll = {}
for i = 1, 1025 do longRoll[i] = 20 end
longRoll[#longRoll + 1] = 10
r = attack({ natural = 20, open_roll = longRoll })
check(r and r.roll_total == 20510 and r.open_count == 1025 and not r.needs_open,
  "continuations have no dice-pool or table-row count cap")
check(r.overflow == 20491, "even a very long open chain is not truncated to the table")

check(engine.registerTable("test", fixture()), "valid custom definition")
local custom = engine.getTable("test")
custom.armors.test[2].quality = 1
check(engine.getTable("test").armors.test[2].quality == 0.25, "getTable must return a copy")
custom = fixture()
check(engine.registerTable("copied", custom), "register source definition")
custom.armors.test[2].quality = 1
check(engine.getTable("copied").armors.test[2].quality == 0.25, "registration must not retain source aliases")

local originalBladed = engine.getTable("bladed")
local legacyReplacement = engine.getTable("sword")
legacyReplacement.label = "Legacy-name replacement"
legacyReplacement.armors.natural_hide[2].quality = 0.12
check(engine.registerTable("sword", legacyReplacement), "legacy registration updates the canonical table")
check(engine.getTable("bladed").label == "Legacy-name replacement"
  and engine.getTable("bladed").armors.natural_hide[2].quality == 0.12,
  "canonical and legacy lookups observe the same complete replacement")
check(engine.getTable("bladed").armors.leather[2].quality == originalBladed.armors.leather[2].quality,
  "a natural column can change independently of its material seed")
check(engine.registerTable("bladed", originalBladed) and engine.getTable("sword").label == originalBladed.label,
  "a later canonical registration also replaces the legacy lookup")
check(engine.registerTable("sword_1h", fixture()) and engine.getTable("sword_1h").label == "Synthetic test fixture",
  "a custom identifier beginning with a legacy name remains an independent table")
check(attack({weapon = "sword_1h", armor = "test"}).table_id == "sword_1h",
  "custom handedness variants are not rewritten by prefix")

local malformed = {
  function(d) d.version = 2 end,
  function(d) d.armors = {} end,
  function(d) d.armors.test[1].min = 1 end,
  function(d) d.armors.test[1].hit = true end,
  function(d) d.armors.test[2].min = 51 end,
  function(d) d.armors.test[2].min = 49 end,
  function(d) d.armors.test[1].max = nil end,
  function(d) d.armors.test[3].max = 150 end,
  function(d) d.armors.test[2].quality = -0.1 end,
  function(d) d.armors.test[2].quality = 1.1 end,
  function(d) d.armors.test[2].quality = 0/0 end,
  function(d) d.armors.test[2].hit = "true" end,
  function(d) d.armors.test[2] = nil end,
  function(d) d.offset = math.huge end,
  function(d) setmetatable(d.armors.test[2], {}) end,
}
for _, corrupt in ipairs(malformed) do
  local bad = fixture()
  corrupt(bad)
  local ok, message = engine.validateTable(bad)
  check(not ok and type(message) == "string", "reject invalid interval definition with an explanation")
  check(not engine.registerTable("test", bad), "invalid replacement rejected")
  check(engine.getTable("test").armors.test[2].quality == 0.25, "failed replacement is atomic")
end
local offset = fixture()
offset.offset = 5
check(engine.registerTable("offset", offset), "offset table")
r = attack({ weapon = "offset", armor = "test", natural = 4, attack_bonus = 5 })
check(r.index == 50 and r.hit, "custom offset applied exactly once")
r = attack({ weapon = "test", armor = "test", natural = 5, attack_bonus = 5 })
check(r.hit and r.quality == 0.25, "inclusive interval lower bound")
r = attack({ weapon = "test", armor = "test", natural = 19, attack_bonus = 1000000 })
check(r.hit and r.quality == 0.75, "final open interval handles very high bonuses")

check(sum(engine.damageDice({ "2d6" }, 0)) == 2, "minimum sum")
check(sum(engine.damageDice({ "2d6" }, 1)) == 12, "maximum sum")
check(sum(engine.damageDice({ "2d6" }, 0.75)) == 9, "2d6 uses a triangular sum CDF")
check(sum(engine.damageDice({ "3d6" }, 0.75)) == 13, "3d6 uses the actual convolution")
check(sum(engine.damageDice({ {type = "d6"}, {sides = 8, count = 2} }, 1)) == 22, "FG and structured descriptors")
check(#engine.damageDice({}, 0.5) == 0, "empty dice pool for fixed damage")
check(engine.damageDice({ "1d6+3" }, 0.5) == nil, "fixed modifiers must remain separate")
check(engine.damageDice({ "-2d6" }, 0.5) == nil, "reject negative dice counts")
check(engine.damageDice({ "0d6" }, 0.5) == nil, "reject zero dice counts")
check(engine.damageDice({ {sides = 6, count = false} }, 0.5) == nil, "reject boolean dice counts")
check(engine.damageDice({ -6 }, 0.5) == nil, "reject negative sides")
check(engine.damageDice({ "d101" }, 0.5) == nil, "die sides limit")
check(engine.damageDice({ "33d6" }, 0.5) == nil, "pool count limit")
check(engine.damageDice({ "21d100" }, 0.5) == nil, "pool sum limit")
check(engine.damageDice({ [1] = 6, [3] = 6 }, 0.5) == nil, "reject sparse dice arrays")
check(engine.damageDice({6}, -0.1) == nil, "reject negative quality")
check(engine.damageDice({6}, 0/0) == nil, "reject NaN quality")
check(engine.damageDice({6}, 1.1) == nil, "reject excessive quality")

-- Repeated floating-point addition must not turn the d12 median from six into
-- seven. Check the adjacent representable doubles as well: no epsilon may
-- silently absorb a quality that is genuinely above the boundary.
local belowHalf, aboveHalf = 0.5 - 2^-54, 0.5 + 2^-53
check(belowHalf < 0.5 and aboveHalf > 0.5, "CDF neighbors must be distinct representable numbers")
for _, sides in ipairs({4,6,8,10,12}) do
  check(sum(engine.damageDice({sides}, 0.5)) == sides/2, "uniform-die exact median boundary")
  check(sum(engine.damageDice({sides}, belowHalf)) == sides/2, "quality immediately below the median stays in its interval")
  check(sum(engine.damageDice({sides}, aboveHalf)) == sides/2+1, "quality immediately above the median advances without tolerance rounding")
end
for _, sides in ipairs({4,8,12}) do
  check(sum(engine.damageDice({sides}, 0.25)) == sides/4, "uniform-die quarter boundary")
  check(sum(engine.damageDice({sides}, 0.25 + 2^-54)) == sides/4+1, "quality above the quarter boundary remains distinguishable")
  check(sum(engine.damageDice({sides}, 0.75)) == sides*3/4, "uniform-die three-quarter boundary")
  check(sum(engine.damageDice({sides}, 0.75 + 2^-53)) == sides*3/4+1, "quality above three quarters remains distinguishable")
end

-- Extra damage is a flat supplement scaled only by the mean of the original
-- base dice pool. Legal die faces and fixed modifiers remain untouched.
local extra, metadata = engine.damageOverflow({"1d8"}, 9)
check(extra == 4 and metadata.mean == 4.5 and metadata.slope == 0.45,
  "1d8 tail adds floor(4.5 times 9 / 10)")
check(engine.damageOverflow({"2d6"}, 9) == 6, "2d6 tail uses mean seven, not a single d6 or a d12")
check(engine.damageOverflow({"1d8"}, 29) == 13, "20 plus 20 plus 10 continues increasing 1d8 damage")
check(engine.damageOverflow({"2d6"}, 29) == 20, "20 plus 20 plus 10 continues increasing 2d6 damage")
check(engine.damageOverflow({"1d8"}, 0) == 0, "tail joins the final row without a forced damage jump")
check(engine.damageOverflow({}, 1000000) == 0, "fixed damage has no invented dice scale")
check(engine.damageOverflow({{type = "d6"}, {sides = 8, count = 2}}, 10) == 12,
  "mixed dice scale by their combined mean before rounding")
check(engine.damageOverflow({"1d8"}, 1000000000000) == 450000000000,
  "huge supported excess has no gameplay damage cap")
check(engine.damageOverflow({"2d6"}, 1000000000000) == 700000000000,
  "large multi-die damage remains proportional to the weapon pool")
for _, badOverflow in ipairs({-1, 0/0, math.huge, -math.huge, "10", false}) do
  local invalid, message = engine.damageOverflow({"1d8"}, badOverflow)
  check(invalid == nil and type(message) == "string", "invalid excess fails with an explanation")
end
check(engine.damageOverflow({"1d8+3"}, 10) == nil, "fixed modifiers do not enter the tail scale")
check(engine.damageOverflow({"33d6"}, 10) == nil, "damage supplement preserves base-pool input validation")
local invalid, precisionError = engine.damageOverflow({"1d8"}, 1e100)
check(invalid == nil and precisionError:find("precision", 1, true) ~= nil,
  "unsupported numeric precision reports failure instead of clamping damage")
for _, pool in ipairs({{"1d8"}, {"2d6"}, {"1d12"}, {"d4", "d8"}}) do
  local previous = -1
  for fifth = 0, 500 do
    local overflow = fifth / 5
    local supplement = engine.damageOverflow(pool, overflow)
    check(supplement >= previous, "overflow damage is monotone above the table")
    previous = supplement
  end
  local atZero, stats = engine.damageOverflow(pool, 0)
  check(engine.damageOverflow(pool, 200) == stats.mean * 20 and atZero == 0,
    "each complete extra twenty increases the supplement by two pool means")
end

-- Each midpoint represents one equiprobable joint outcome. The inverse sum
-- CDF and conditional allocation must enumerate all tuples exactly once.
for _, dice in ipairs({ {6,6}, {6,6,6}, {4,6,8} }) do
  local outcomes, seen, expectedHistogram, actualHistogram = 1, {}, {}, {}
  for _, sides in ipairs(dice) do outcomes = outcomes * sides end
  local function enumerate(index, subtotal)
    if index > #dice then
      expectedHistogram[subtotal] = (expectedHistogram[subtotal] or 0) + 1
      return
    end
    for face = 1, dice[index] do enumerate(index + 1, subtotal + face) end
  end
  enumerate(1, 0)
  local previousSum = -1
  for i = 1, outcomes do
    local values, message = engine.damageDice(dice, (i - 0.5) / outcomes)
    check(values ~= nil, message)
    local total, key = sum(values), table.concat(values, ",")
    check(not seen[key], "conditional allocation preserves individual joint outcomes")
    seen[key] = true
    check(total >= previousSum, "damage sum must be monotone with quality")
    for j = 1, #dice do check(values[j] >= 1 and values[j] <= dice[j], "valid per-die faces") end
    actualHistogram[total] = (actualHistogram[total] or 0) + 1
    previousSum = total
  end
  for total, count in pairs(expectedHistogram) do
    check(actualHistogram[total] == count, "exact discrete sum histogram")
  end
end

-- Exercise upper supported pools and cache churn without exponential work.
for sides = 2, 24 do
  local values = engine.damageDice({ {sides = sides, count = 16} }, 0.731)
  check(values and #values == 16, "bounded convolution and cache churn")
end
local values = engine.damageDice({ "20d100" }, 0.999999)
check(values and #values == 20 and sum(values) <= 2000, "largest supported sum")
values = engine.damageDice({ "32d6" }, 0.000001)
check(values and #values == 32 and sum(values) >= 32, "largest supported count")
check(engine.registerDefaultTables() == 0, "default registration is idempotent")
print("engine tests passed (" .. checks .. " assertions)")
