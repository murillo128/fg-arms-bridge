-- Arms Bridge: a dependency-free combat experiment for Lua 5.1 and later.
-- The bundled curves are ORIGINAL DEMO DATA. They are not Arms Law tables,
-- Iron Crown Enterprises content, or a claim of calibrated D&D balance.
--
-- Fantasy Grounds exposes the global functions in this file through the named
-- script scope, ArmsEngine. Standalone callers can use the table returned by
-- dofile(). No import in this module evaluates Lua or executes table content.

local VERSION = "0.3.1"
local MAX_DICE = 32
local MAX_SIDES = 100
local MAX_SUM = 2000
local MAX_CACHE = 16
local MAX_ROWS = 512
local MAX_ARMORS = 64
local MAX_INDEX = 1000000000
-- This is a numeric precision guard, not an attack/damage rule or a clamp.
-- Lua 5.1 uses doubles; integers above this value are no longer all exact.
local MAX_SAFE_INTEGER = 9007199254740991
local registry = {}
local diceCache = {}
local cacheCount = 0
local cacheClock = 0
local FAMILIES = {
  { id = "blunted", label = "Blunted weapons", aliases = {"mace"} },
  { id = "bladed", label = "Bladed weapons", aliases = {"sword"} },
  { id = "axes", label = "Axes", aliases = {"axe"} },
  { id = "polearms", label = "Pole arms", aliases = {"spear"} },
  { id = "bows", label = "Bows", aliases = {"bow"} },
  { id = "crossbows", label = "Crossbows", aliases = {} },
  { id = "exotic", label = "Exotic", aliases = {} },
  { id = "firearms", label = "Firearms", aliases = {} },
}
local LEGACY_FAMILIES = {}
for _, family in ipairs(FAMILIES) do
  for _, alias in ipairs(family.aliases) do LEGACY_FAMILIES[alias] = family.id end
end

-- Exact legacy names share the canonical registry entry. Custom identifiers,
-- including optional names such as bladed_2h or sword_1h, stay unchanged.
-- CSV/batch collision checks belong to the data importer; a later explicit
-- registration replaces the entire canonical table, as in earlier versions.
function canonicalTableId(id)
  if type(id) ~= "string" then return nil end
  return LEGACY_FAMILIES[id] or id
end

function getFamilies()
  local copy = {}
  for i, family in ipairs(FAMILIES) do
    local aliases = {}
    for j, alias in ipairs(family.aliases) do aliases[j] = alias end
    copy[i] = { id = family.id, label = family.label, aliases = aliases }
  end
  return copy
end

function getDefaultTableIds()
  local ids = {}
  for i, family in ipairs(FAMILIES) do ids[i] = family.id end
  return ids
end

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function integer(value)
  return finite(value) and value == math.floor(value)
end

-- Compensated accumulation retains low-order terms lost by repeated addition.
-- It changes no percentile thresholds and introduces no epsilon that could
-- merge two distinct qualities on opposite sides of a CDF boundary.
local function compensatedAdd(total, correction, value)
  local adjusted = value - correction
  local nextTotal = total + adjusted
  return nextTotal, (nextTotal - total) - adjusted
end

local function boundedText(value, limit)
  return type(value) == "string" and #value > 0 and #value <= limit
    and not value:find("[%c]")
end

local function plainTable(value)
  return type(value) == "table" and getmetatable(value) == nil
end

local function arrayLength(value, maximum, name)
  if not plainTable(value) then
    return nil, name .. " must be a plain array"
  end
  local count, largest = 0, 0
  for key in pairs(value) do
    if not integer(key) or key < 1 then
      return nil, name .. " must have consecutive positive integer keys"
    end
    count = count + 1
    if key > largest then largest = key end
    if count > maximum then return nil, name .. " exceeds its size limit" end
  end
  if largest ~= count then return nil, name .. " must not contain gaps" end
  return count
end

local function cloneDefinition(definition)
  local copy = {
    version = definition.version,
    label = definition.label,
    provenance = definition.provenance,
    offset = definition.offset or 0,
    armors = {},
  }
  for armor, rows in pairs(definition.armors) do
    local target = {}
    for i = 1, #rows do
      local row = rows[i]
      target[i] = {
        min = row.min, max = row.max, hit = row.hit, quality = row.quality,
      }
    end
    copy.armors[armor] = target
  end
  return copy
end

-- Version 1 definitions describe inclusive INTEGER intervals. The first row
-- covers at least zero and must be a miss; indices below it clamp to that row.
-- Every later interval must follow its predecessor without gaps/overlaps.
-- The final interval has no max and therefore covers arbitrarily high indices.
function validateTable(definition)
  if not plainTable(definition) then return false, "definition must be a plain table" end
  if definition.version ~= 1 then return false, "unsupported table version (expected 1)" end
  if not boundedText(definition.label, 200) then return false, "label must be nonempty text (maximum 200 characters)" end
  if not boundedText(definition.provenance, 2000) then return false, "provenance must be nonempty text (maximum 2000 characters)" end
  if definition.offset ~= nil and (not integer(definition.offset) or math.abs(definition.offset) > MAX_INDEX) then
    return false, "offset must be a finite integer within the supported range"
  end
  if not plainTable(definition.armors) then return false, "armors must be a plain table" end
  local armorCount = 0
  for armor, rows in pairs(definition.armors) do
    armorCount = armorCount + 1
    if armorCount > MAX_ARMORS then return false, "too many armor profiles" end
    if not boundedText(armor, 64) then return false, "armor ids must be nonempty text (maximum 64 characters)" end
    local count, arrayError = arrayLength(rows, MAX_ROWS, "rows for " .. armor)
    if not count then return false, arrayError end
    if count < 2 then return false, "armor " .. armor .. " needs an initial miss row and a final open interval" end
    local previousMax
    for i = 1, count do
      local row = rows[i]
      local prefix = "armor " .. armor .. ", row " .. i .. ": "
      if not plainTable(row) then return false, prefix .. "row must be a plain table" end
      if not integer(row.min) or math.abs(row.min) > MAX_INDEX then
        return false, prefix .. "min must be a finite integer within the supported range"
      end
      if i == 1 then
        if row.min > 0 then return false, prefix .. "first interval must cover zero" end
        if row.hit ~= false or row.quality ~= 0 then return false, prefix .. "first interval must be a miss with quality zero" end
      elseif row.min ~= previousMax + 1 then
        return false, prefix .. "intervals must be ordered, contiguous, and non-overlapping"
      end
      if row.max == nil then
        if i ~= count then return false, prefix .. "only the last interval may omit max" end
      elseif not integer(row.max) or math.abs(row.max) > MAX_INDEX or row.max < row.min then
        return false, prefix .. "max must be an integer at least min within the supported range"
      elseif i == count then
        return false, prefix .. "last interval must omit max for complete upper coverage"
      end
      if type(row.hit) ~= "boolean" then return false, prefix .. "hit must be boolean" end
      if not finite(row.quality) or row.quality < 0 or row.quality > 1 then
        return false, prefix .. "quality must be a finite number between zero and one"
      end
      if not row.hit and row.quality ~= 0 then return false, prefix .. "a miss must have quality zero" end
      previousMax = row.max
    end
  end
  if armorCount == 0 then return false, "at least one armor profile is required" end
  return true
end

-- Registration is atomic. Invalid replacements do not change the prior table.
-- Stored and returned definitions are copies, so callers cannot mutate a
-- validated registry entry through an alias.
function registerTable(id, definition)
  if not boundedText(id, 96) then return false, "table id must be nonempty text (maximum 96 characters)" end
  local ok, validationError = validateTable(definition)
  if not ok then return false, validationError end
  registry[canonicalTableId(id)] = cloneDefinition(definition)
  return true
end

function getTable(id)
  local canonical = canonicalTableId(id)
  local definition = canonical and registry[canonical]
  if not definition then return nil end
  return cloneDefinition(definition)
end

function listTables()
  local ids = {}
  for id in pairs(registry) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

local function findRow(rows, index)
  local low, high = 1, #rows
  while low <= high do
    local middle = math.floor((low + high) / 2)
    local row = rows[middle]
    if index < row.min then
      high = middle - 1
    elseif row.max ~= nil and index > row.max then
      low = middle + 1
    else
      return row
    end
  end
  return nil -- Defensive only: validated, clamped intervals cover every index.
end

-- The selected initial d20 opens on 20. Every continuation is an ordinary d20:
-- a further 20 continues the chain, while any 1..19 closes it. A continuation
-- of 1 adds one; it cannot change the identity of the initial natural die.
-- Arrays ending in 20 are valid pending attacks. There is no rule limiting the
-- number of continuations; impossible-to-represent totals fail explicitly.
local function resolveOpenRoll(natural, supplied)
  local rolls = supplied
  if rolls == nil then rolls = { natural } end
  local count, arrayError = arrayLength(rolls, MAX_SAFE_INTEGER, "open_roll")
  if not count then return nil, arrayError end
  if count == 0 then return nil, "open_roll must contain the initial d20" end
  if rolls[1] ~= natural then return nil, "open_roll must begin with natural" end
  local total, opened, copy = 0, 0, {}
  for i = 1, count do
    local face = rolls[i]
    if not integer(face) or face < 1 or face > 20 then
      return nil, "open_roll faces must be integers from 1 to 20"
    end
    if i < count and face ~= 20 then
      return nil, "only a 20 may be followed by another open_roll die"
    end
    if total > MAX_SAFE_INTEGER - face then
      return nil, "open_roll total exceeds exact numeric precision; no result was truncated"
    end
    total = total + face
    if face == 20 then opened = opened + 1 end
    copy[i] = face
  end
  return { total = total, count = opened, pending = rolls[count] == 20, rolls = copy }
end

-- opts: natural, attack_bonus, defense, armor, weapon, optional open_roll array,
-- and optional boolean crit / force_hit / force_miss. open_roll includes the
-- initial natural die and all continuations received so far. Without it, a
-- natural 20 is an unfinished open roll, not a silently completed attack.
-- The index before quantization is exactly
-- 5 * (sum(open_roll) + attack_bonus - defense) + table.offset. Fractional
-- indices round down for lookup. The initial natural remains separate.
--
-- Precedence: natural 1 -> miss; natural 20 -> hit and critical; otherwise
-- force_miss -> miss; crit -> hit and critical; force_hit -> hit; table result.
-- A forced noncritical hit on a miss row uses neutral quality 0.5. Critical
-- results report quality 1 as attack information. The Fantasy Grounds bridge
-- leaves critical dice native and adds only the separately computed overflow.
-- A complete hit beyond the final interval's start has overflow measured in
-- d20 units. Quality stays a valid percentile; overflow has no rule-based cap.
function resolve(opts)
  if not plainTable(opts) then return nil, "attack options must be a plain table" end
  if not integer(opts.natural) or opts.natural < 1 or opts.natural > 20 then
    return nil, "natural must be an integer from 1 to 20"
  end
  local open, openError = resolveOpenRoll(opts.natural, opts.open_roll)
  if not open then return nil, openError end
  for _, field in ipairs({ "attack_bonus", "defense" }) do
    if not finite(opts[field]) or math.abs(opts[field]) > MAX_INDEX then
      return nil, field .. " must be a finite number within the supported range"
    end
  end
  for _, field in ipairs({ "crit", "force_hit", "force_miss" }) do
    if opts[field] ~= nil and type(opts[field]) ~= "boolean" then
      return nil, field .. " must be boolean when supplied"
    end
  end
  if not boundedText(opts.weapon, 96) then return nil, "weapon must identify a registered table" end
  if not boundedText(opts.armor, 64) then return nil, "armor must identify an armor profile" end
  local tableId = canonicalTableId(opts.weapon)
  local definition = registry[tableId]
  if not definition then return nil, "unknown weapon table: " .. opts.weapon end
  local rows = definition.armors[opts.armor]
  if not rows then return nil, "unknown armor profile: " .. opts.armor end
  local score = open.total + opts.attack_bonus - opts.defense
  if not finite(score) or math.abs(score) > (MAX_SAFE_INTEGER - math.abs(definition.offset)) / 5 then
    return nil, "attack index exceeds exact numeric precision; no result was truncated"
  end
  local rawIndex = 5 * score + definition.offset
  local index = math.floor(rawIndex)
  local clamped = index < rows[1].min
  if clamped then index = rows[1].min end
  local row = findRow(rows, index)
  if not row then return nil, "table lookup has no interval for the requested index" end
  local hit, critical, quality, reason = row.hit, false, row.quality, "table"
  if opts.natural == 1 then
    hit, critical, quality, reason = false, false, 0, "natural_one"
  elseif opts.natural == 20 then
    hit, critical, quality, reason = true, true, 1, "natural_twenty"
  elseif opts.force_miss then
    hit, critical, quality, reason = false, false, 0, "forced_miss"
  elseif opts.crit then
    hit, critical, quality, reason = true, true, 1, "native_critical"
  elseif opts.force_hit then
    hit, reason = true, "forced_hit"
    if not row.hit then quality = 0.5 end
  end
  local overflow = 0
  if hit and not open.pending then
    overflow = math.max(0, (index - rows[#rows].min) / 5)
  end
  return {
    hit = hit,
    critical = critical,
    quality = quality,
    index = index,
    raw_index = rawIndex,
    quantized = rawIndex ~= math.floor(rawIndex),
    clamped = clamped,
    table_id = tableId,
    requested_table_id = opts.weapon,
    table_label = definition.label,
    armor = opts.armor,
    natural = opts.natural,
    open_roll = open.rolls,
    roll_total = open.total,
    open_count = open.count,
    needs_open = open.pending,
    overflow = overflow,
    overflow_start = rows[#rows].min,
    attack_bonus = opts.attack_bonus,
    defense = opts.defense,
    reason = reason,
    provenance = definition.provenance,
    row_min = row.min,
    row_max = row.max,
    table_hit = row.hit,
    table_quality = row.quality,
  }
end

local function parseDieString(value)
  local count, sides = value:match("^%s*(%d*)[dD](%d+)%s*$")
  if not sides then return nil, nil, "die strings must be dN or XdN without modifiers" end
  if count == "" then count = 1 else count = tonumber(count) end
  return tonumber(sides), count
end

local function normalizeDice(specs)
  local entries, arrayError = arrayLength(specs, MAX_DICE, "diceSpecs")
  if not entries then return nil, arrayError end
  local dice, maximumSum = {}, 0
  for i = 1, entries do
    local spec, sides, count = specs[i], nil, 1
    if type(spec) == "number" then
      sides = spec
    elseif type(spec) == "string" then
      local parseError
      sides, count, parseError = parseDieString(spec)
      if not sides then return nil, "die " .. i .. ": " .. parseError end
    elseif plainTable(spec) then
      if spec.sides ~= nil then
        if spec.type ~= nil then return nil, "die " .. i .. ": use sides or type, not both" end
        sides = spec.sides
        if spec.count ~= nil then count = spec.count end
      elseif type(spec.type) == "string" then
        local parseError
        sides, count, parseError = parseDieString(spec.type)
        if not sides then return nil, "die " .. i .. ": " .. parseError end
        if spec.count ~= nil then
          if not integer(spec.count) then return nil, "die " .. i .. ": count must be an integer" end
          count = count * spec.count
        end
      else
        return nil, "die " .. i .. ": descriptor needs sides or a standard die type"
      end
    else
      return nil, "die " .. i .. ": unsupported die specification"
    end
    if not integer(sides) or sides < 1 or sides > MAX_SIDES then
      return nil, "die " .. i .. ": sides must be an integer from 1 to " .. MAX_SIDES
    end
    if not integer(count) or count < 1 or count > MAX_DICE then
      return nil, "die " .. i .. ": count must be a positive integer at most " .. MAX_DICE
    end
    if #dice + count > MAX_DICE then return nil, "dice pool exceeds " .. MAX_DICE .. " dice" end
    maximumSum = maximumSum + count * sides
    if maximumSum > MAX_SUM then return nil, "dice pool maximum sum exceeds " .. MAX_SUM end
    for _ = 1, count do dice[#dice + 1] = sides end
  end
  return dice
end

-- Uniform dice have symmetric sum distributions, even with mixed die sizes.
-- A sliding convolution window computes the first half, then mirrors it. This
-- avoids both the O(sides * sum) convolution and cancellation in tiny upper
-- tails. These are full discrete probabilities, not a Gaussian approximation.
local function buildPool(dice)
  local suffix = {}
  suffix[#dice + 1] = { min = 0, max = 0, p = { [0] = 1 } }
  for i = #dice, 1, -1 do
    local nextDistribution = suffix[i + 1]
    local minimum = nextDistribution.min + 1
    local maximum = nextDistribution.max + dice[i]
    local distribution = { min = minimum, max = maximum, p = {} }
    local center = math.floor((minimum + maximum) / 2)
    local window, total, totalCorrection = 0, 0, 0
    for sum = minimum, center do
      window = window + (nextDistribution.p[sum - 1] or 0)
        - (nextDistribution.p[sum - dice[i] - 1] or 0)
      local probability = math.max(0, window / dice[i])
      local mirror = minimum + maximum - sum
      distribution.p[sum] = probability
      distribution.p[mirror] = probability
      total, totalCorrection = compensatedAdd(total, totalCorrection, probability)
      if mirror ~= sum then total, totalCorrection = compensatedAdd(total, totalCorrection, probability) end
    end
    for sum = minimum, maximum do
      distribution.p[sum] = distribution.p[sum] / total
    end
    suffix[i] = distribution
  end
  return { suffix = suffix }
end

local function getPool(dice)
  local key = table.concat(dice, ",")
  cacheClock = cacheClock + 1
  local pool = diceCache[key]
  if pool then pool.used = cacheClock; return pool end
  pool = buildPool(dice)
  if cacheCount >= MAX_CACHE then
    local oldestKey, oldestUse
    for candidate, item in pairs(diceCache) do
      if not oldestUse or item.used < oldestUse then
        oldestKey, oldestUse = candidate, item.used
      end
    end
    diceCache[oldestKey] = nil
  else
    cacheCount = cacheCount + 1
  end
  pool.used = cacheClock
  diceCache[key] = pool
  return pool
end

-- Returns one number per expanded die, in the input order, or nil,error.
-- Accepted entries: 6, "d6", "2d6", {sides=6,count=2}, {type="d6"}.
-- Fixed damage modifiers do not belong in this input.
--
-- The sum is the inverse CDF at quality. The fractional position within the
-- selected sum's probability mass then selects a valid joint outcome,
-- conditioned on that sum. With uniform quality, all original joint outcomes
-- retain their probabilities; dice are not incorrectly forced to equal faces.
-- Arithmetic uses Lua numbers, so CDF boundaries have floating-point precision.
function damageDice(diceSpecs, quality)
  if not finite(quality) or quality < 0 or quality > 1 then
    return nil, "quality must be a finite number between zero and one"
  end
  local dice, diceError = normalizeDice(diceSpecs)
  if not dice then return nil, diceError end
  local results = {}
  if #dice == 0 then return results end
  if quality == 0 or quality == 1 then
    for i = 1, #dice do results[i] = quality == 0 and 1 or dice[i] end
    return results
  end
  local pool = getPool(dice)
  local distribution = pool.suffix[1]
  local cumulative, cumulativeCorrection, selectedSum, unit = 0, 0, distribution.max, 1
  for sum = distribution.min, distribution.max do
    local probability = distribution.p[sum]
    local nextCumulative, nextCorrection = compensatedAdd(cumulative, cumulativeCorrection, probability)
    if probability > 0 and quality <= nextCumulative then
      selectedSum = sum
      unit = math.max(0, math.min(1, (quality - cumulative) / probability))
      break
    end
    cumulative, cumulativeCorrection = nextCumulative, nextCorrection
  end
  local remaining = selectedSum
  for i = 1, #dice do
    local nextDistribution = pool.suffix[i + 1]
    local denominator = 0
    for face = 1, dice[i] do denominator = denominator + (nextDistribution.p[remaining - face] or 0) end
    if denominator <= 0 then return nil, "numerical failure while allocating a dice sum" end
    local before, chosen, chosenBefore, chosenProbability = 0, nil, 0, 0
    for face = 1, dice[i] do
      local probability = (nextDistribution.p[remaining - face] or 0) / denominator
      if probability > 0 then
        -- Retain the final valid branch as a rounding-safe fallback for unit=1.
        chosen, chosenBefore, chosenProbability = face, before, probability
        if unit <= before + probability then break end
      end
      before = before + probability
    end
    if not chosen then return nil, "numerical failure while selecting a die face" end
    results[i] = chosen
    remaining = remaining - chosen
    unit = math.max(0, math.min(1, (unit - chosenBefore) / chosenProbability))
  end
  if remaining ~= 0 then return nil, "dice allocation did not conserve the selected sum" end
  return results
end

-- An extra ten d20 points above the table's last-band start add one mean
-- base-weapon dice pool. Round only the combined supplement down; do not round
-- per die, multiply fixed modifiers, duplicate critical dice, or set a die face
-- above its sides. The native bridge attaches this supplement to the base
-- weapon damage clause once, after native critical dice have been determined.
-- Returns integer damage,metadata on success, or nil,error. The metadata is
-- diagnostic and does not need to be serialized into a Fantasy Grounds roll.
function damageOverflow(diceSpecs, overflow)
  if not finite(overflow) or overflow < 0 then
    return nil, "overflow must be a finite nonnegative number"
  end
  local dice, diceError = normalizeDice(diceSpecs)
  if not dice then return nil, diceError end
  local mean = 0
  for _, sides in ipairs(dice) do mean = mean + (sides + 1) / 2 end
  local rawDamage = mean * overflow / 10
  if not finite(rawDamage) or rawDamage > MAX_SAFE_INTEGER then
    return nil, "overflow damage exceeds exact numeric precision; no damage was truncated"
  end
  return math.floor(rawDamage), { mean = mean, slope = mean / 10, raw_damage = rawDamage }
end

function getVersion()
  return VERSION
end

local DEMO_PROVENANCE = "Original Arms Bridge demo curves; not Iron Crown Enterprises or Arms Law data. Experimental and not certified as balanced D&D rules. Natural hide/scales/shell are independent copies seeded from leather/mail/plate; no official equivalence is claimed."

local function makeRows(points)
  local rows = { { min = 0, max = points[1][1] - 1, hit = false, quality = 0 } }
  for i = 1, #points do
    rows[#rows + 1] = {
      min = points[i][1],
      max = points[i + 1] and (points[i + 1][1] - 1) or nil,
      hit = true,
      quality = points[i][2],
    }
  end
  return rows
end

local function shifted(points, shift)
  local output = {}
  for i = 1, #points do output[i] = { points[i][1] + shift, points[i][2] } end
  return output
end

-- These fixed, original profiles are a replaceable test fixture, not a
-- Rolemaster conversion. Crossbows/firearms reuse the bows shape; exotic reuses
-- bladed. Natural profiles start from the corresponding material seeds below,
-- each with independent rows. These deliberate copies are not claims about
-- equivalent real protection or calibrated weapon penetration. Simple/martial
-- category and one/two-handed use do not add a bonus in this engine.
function registerDefaultTables()
  local open = { {50, 0.10}, {60, 0.20}, {70, 0.35}, {80, 0.50}, {90, 0.65}, {100, 0.80}, {110, 0.90}, {120, 1.00} }
  local leather = { {55, 0.10}, {65, 0.25}, {75, 0.40}, {85, 0.55}, {95, 0.70}, {105, 0.85}, {115, 0.95}, {125, 1.00} }
  local mail = { {80, 0.15}, {90, 0.35}, {100, 0.55}, {110, 0.75}, {120, 0.90}, {130, 1.00} }
  local plate = { {90, 0.25}, {100, 0.45}, {110, 0.70}, {120, 0.90}, {130, 1.00} }
  local profiles = {
    bladed = { unarmored = open, leather = leather, mail = mail, plate = plate },
    blunted = { unarmored = shifted(open, 5), leather = shifted(leather, 5), mail = shifted(mail, -5), plate = shifted(plate, -10) },
    polearms = { unarmored = open, leather = shifted(leather, -5), mail = shifted(mail, -5), plate = shifted(plate, -5) },
    axes = { unarmored = shifted(open, -5), leather = shifted(leather, -5), mail = shifted(mail, 5), plate = shifted(plate, 5) },
    bows = { unarmored = open, leather = leather, mail = shifted(mail, 5), plate = shifted(plate, 10) },
  }
  profiles.crossbows = profiles.bows
  profiles.exotic = profiles.bladed
  profiles.firearms = profiles.bows
  local naturalSeeds = { natural_hide = "leather", natural_scales = "mail", natural_shell = "plate" }
  local familySeeds = { crossbows = "bows", exotic = "bladed", firearms = "bows" }
  local registered = 0
  for _, family in ipairs(FAMILIES) do
    local id, profile = family.id, profiles[family.id]
    if not registry[id] then
      local provenance = DEMO_PROVENANCE
      if familySeeds[id] then provenance = provenance .. " This family currently uses the " .. familySeeds[id] .. " demo shape as its seed." end
      local definition = { version = 1, label = "Original demo: " .. family.label, provenance = provenance, offset = 0, armors = {} }
      for armor, points in pairs(profile) do definition.armors[armor] = makeRows(points) end
      for natural, seed in pairs(naturalSeeds) do definition.armors[natural] = makeRows(profile[seed]) end
      local ok, registrationError = registerTable(id, definition)
      if not ok then return nil, registrationError end
      registered = registered + 1
    end
  end
  return registered
end

registerDefaultTables()

return {
  canonicalTableId = canonicalTableId,
  getFamilies = getFamilies,
  getDefaultTableIds = getDefaultTableIds,
  validateTable = validateTable,
  registerTable = registerTable,
  getTable = getTable,
  listTables = listTables,
  resolve = resolve,
  damageDice = damageDice,
  damageOverflow = damageOverflow,
  getVersion = getVersion,
  registerDefaultTables = registerDefaultTables,
}
