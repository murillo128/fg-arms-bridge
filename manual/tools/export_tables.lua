-- Reproducible export of the ORIGINAL Arms Bridge 0.3.1 demo curves.
-- No engine source file is modified.
-- From repository root: lua manual/tools/export_tables.lua [engine.lua] [output.json]
-- Defaults resolve relative to this script, not the current working directory.
-- A Lua executable is optional; the existing tools/test.py library worker can
-- execute this script using liblua5.4 with no third-party JSON library.

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local scriptDir = source:match("^(.*)[/\\]") or "."
local arguments = type(arg) == "table" and arg or {}
local enginePath = arguments[1] or (scriptDir .. "/../../extension/scripts/arms_engine.lua")
local outputPath = arguments[2] or os.getenv("ARMSBRIDGE_TABLE_OUTPUT") or (scriptDir .. "/../data/tables.json")
local Engine = dofile(enginePath)
assert(Engine.getVersion() == "0.3.1", "this book export is pinned to engine 0.3.1")

local NULL, ARRAY = {}, {}
local function array(values) return setmetatable(values or {}, ARRAY) end
local function copyArray(values)
  local result = array()
  for i, value in ipairs(values) do result[i] = value end
  return result
end
local function quote(value)
  local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
  return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
    return escapes[c] or string.format("\\u%04x", string.byte(c))
  end) .. '"'
end
local function json(value, level)
  if value == NULL then return "null" end
  local kind = type(value)
  if kind == "string" then return quote(value) end
  if kind == "boolean" then return value and "true" or "false" end
  if kind == "number" then
    assert(value == value and math.abs(value) ~= math.huge, "JSON numbers must be finite")
    return string.format("%.15g", value)
  end
  assert(kind == "table", "unsupported JSON value: " .. kind)
  local indent, nextIndent = string.rep("  ", level), string.rep("  ", level + 1)
  local pieces = {}
  if getmetatable(value) == ARRAY then
    for i = 1, #value do pieces[#pieces + 1] = nextIndent .. json(value[i], level + 1) end
    if #pieces == 0 then return "[]" end
    return "[\n" .. table.concat(pieces, ",\n") .. "\n" .. indent .. "]"
  end
  local keys = {}
  for key in pairs(value) do assert(type(key) == "string"); keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do pieces[#pieces + 1] = nextIndent .. quote(key) .. ": " .. json(value[key], level + 1) end
  if #pieces == 0 then return "{}" end
  return "{\n" .. table.concat(pieces, ",\n") .. "\n" .. indent .. "}"
end
local function sum(values)
  local total = 0
  for _, value in ipairs(values) do total = total + value end
  return total
end
local armorIds = {"unarmored", "leather", "mail", "plate", "natural_hide", "natural_scales", "natural_shell"}
local armorLabels = {"Sin protección", "Cuero", "Malla", "Placas", "Piel dura", "Escamas", "Caparazón"}
local poolIds = {"d4", "d6", "d8", "d10", "d12", "2d6", "fixed1"}
local poolSpecs = {d4={4}, d6={6}, d8={8}, d10={10}, d12={12}, ["2d6"]={6,6}, fixed1={}}
local minR, maxR = 0, 35
local export = {
  schema_version = 1,
  engine_version = Engine.getVersion(),
  source_engine = "extension/scripts/arms_engine.lua",
  source_kind = "original_demo_not_ICE_or_Arms_Law_tables",
  family_order = copyArray(Engine.getDefaultTableIds()),
  armor_order = copyArray(armorIds),
  pool_order = copyArray(poolIds),
  armor_profiles = array(),
  pools = {},
  families = {},
  grid = {first_r = minR, first_label = "≤0", last_printed_r = maxR, step = 1,
    last_printed_r_is_damage_cap = false, maximum_r = NULL,
    r_definition = "R = T + B - E", t_definition = "sum of initial d20 and all open continuations",
    lookup_method = "Engine.resolve with natural=10, attack_bonus=R-10, defense=0; natural overrides are applied separately"},
  rules = {modifier_added_once_outside_cells = true,
    ordinary_damage = "base + supplement + M",
    tail_formula = "floor(mu * max(0, R - R0) / 10)",
    r0_definition = "L/5, where L is the start index of the last source-table interval; default offsets are zero",
    critical_damage = "native critical dice + M + supplement once",
    critical_base_is_not_maximized = true, supplement_is_not_doubled = true,
    initial_one = "automatic miss", initial_twenty = "automatic hit, one native D&D critical, and an open continuation",
    continuation_twenty = "add twenty and continue", continuation_one = "add one and finish; not a fumble",
    natural_overrides_external_to_grid = true,
    fixed1 = "native-only fixed damage 1 on a table hit; unsupported_table_conversion, no open damage growth"},
  validation = {lookup_points = 0, engine_damage_calls = 0, fixed_native_derivations = 0,
    grouped_range_checks = 0, high_tail_checks = 0},
  examples = array(),
}
for i, id in ipairs(armorIds) do
  export.armor_profiles[i] = {id = id, label = armorLabels[i], assigned_explicitly = id:find("^natural_") ~= nil}
end
for _, id in ipairs(poolIds) do
  local specs, mean = poolSpecs[id], 0
  for _, sides in ipairs(specs) do mean = mean + (sides + 1) / 2 end
  local criticalDice = copyArray(specs)
  for _, sides in ipairs(specs) do criticalDice[#criticalDice + 1] = sides end
  export.pools[id] = {id = id, dice = copyArray(specs), mu = mean,
    minimum_base = id == "fixed1" and 1 or #specs,
    maximum_base = id == "fixed1" and 1 or sum(specs),
    native_critical_dice = criticalDice, native_fixed_base = id == "fixed1" and 1 or NULL,
    unsupported_table_conversion = id == "fixed1", native_only = id == "fixed1"}
end

local function labelRange(first, last)
  if first == NULL then return "≤" .. last end
  return first == last and tostring(first) or (first .. "–" .. last)
end
local function groupRows(rows)
  local grouped, previousKey = array(), nil
  for i, row in ipairs(rows) do
    local key = json(row.totals, 0)
    if key == previousKey then
      local item = grouped[#grouped]
      item.r_max, item.end_index = row.r, i - 1
      item.label = labelRange(item.r_min, item.r_max)
    else
      local first = row.r == 0 and NULL or row.r
      grouped[#grouped + 1] = {r_min = first, r_max = row.r, label = labelRange(first, row.r),
        start_index = i - 1, end_index = i - 1, totals = row.totals}
    end
    previousKey = key
  end
  local checked = 0
  for _, item in ipairs(grouped) do
    for index = item.start_index, item.end_index do
      assert(json(item.totals, 0) == json(rows[index + 1].totals, 0), "grouped range altered a displayed result")
      checked = checked + 1
    end
  end
  assert(checked == #rows, "grouped rows must partition the complete printed grid")
  export.validation.grouped_range_checks = export.validation.grouped_range_checks + checked
  return grouped
end

for _, family in ipairs(Engine.getFamilies()) do
  local definition = assert(Engine.getTable(family.id))
  assert(Engine.validateTable(definition))
  assert(definition.offset == 0, "R0=L/5 assumes the zero offsets of the 0.3.1 demo")
  local f = {id = family.id, label = family.label, aliases = copyArray(family.aliases),
    provenance = definition.provenance, offset = definition.offset, columns = {},
    lookup_rows = array(), grids = {}, versatile = {}}
  export.families[family.id] = f
  for _, armor in ipairs(armorIds) do
    local rows = assert(definition.armors[armor])
    local last = rows[#rows]
    assert(last.max == nil, "a source table must retain its unbounded final interval")
    local column = {armor_id = armor, tail_start_index = last.min, tail_start_r = last.min/5,
      last_quality = last.quality, maximum_index = NULL, maximum_r = NULL, source_rows = array()}
    f.columns[armor] = column
    for i, row in ipairs(rows) do
      column.source_rows[i] = {min = row.min, max = row.max or NULL, hit = row.hit, quality = row.quality,
        integer_r_min = i == 1 and NULL or math.ceil(row.min/5),
        integer_r_max = row.max and math.floor(row.max/5) or NULL}
    end
  end
  for r = minR, maxR do
    local lookup = {r = r, label = r == 0 and "≤0" or tostring(r), cells = array()}
    f.lookup_rows[#f.lookup_rows + 1] = lookup
    for a, armor in ipairs(armorIds) do
      local result = assert(Engine.resolve({natural=10, attack_bonus=r-10, defense=0, weapon=family.id, armor=armor}))
      assert(not result.critical and not result.needs_open, "printed grid must contain ordinary completed table results")
      assert(result.index == 5*r, "grid R does not match the engine table index")
      lookup.cells[a] = {hit=result.hit, quality=result.quality, index=result.index,
        overflow_d20=result.overflow, source_row_min=result.row_min, source_row_max=result.row_max or NULL}
      export.validation.lookup_points = export.validation.lookup_points + 1
    end
  end
  for _, poolId in ipairs(poolIds) do
    local specs = poolSpecs[poolId]
    local grid = {pool_id=poolId, native_only=poolId=="fixed1", unsupported_table_conversion=poolId=="fixed1",
      full_rows=array(), grouped_rows=array(), maximum_r=NULL, last_printed_r=maxR}
    f.grids[poolId] = grid
    for _, lookup in ipairs(f.lookup_rows) do
      local row = {r=lookup.r, label=lookup.label, cells=array(), totals=array()}
      grid.full_rows[#grid.full_rows+1] = row
      for a, result in ipairs(lookup.cells) do
        if not result.hit then
          row.cells[a], row.totals[a] = NULL, NULL
        elseif poolId == "fixed1" then
          assert(Engine.damageOverflow({}, result.overflow_d20) == 0, "fixed damage must not acquire an invented dice scale")
          row.cells[a] = {base=1, supplement=0, total=1, dice=NULL,
            unsupported_table_conversion=true, native_only=true, source="native fixed constant on table hit"}
          row.totals[a] = 1
          export.validation.fixed_native_derivations = export.validation.fixed_native_derivations + 1
        else
          local dice = assert(Engine.damageDice(specs, result.quality))
          local extra = assert(Engine.damageOverflow(specs, result.overflow_d20))
          assert(#dice == #specs)
          for i, face in ipairs(dice) do assert(face >= 1 and face <= specs[i] and face % 1 == 0) end
          local base = sum(dice)
          row.cells[a] = {base=base, supplement=extra, total=base+extra, dice=copyArray(dice),
            unsupported_table_conversion=false, native_only=false}
          row.totals[a] = base+extra
          export.validation.engine_damage_calls = export.validation.engine_damage_calls + 1
        end
      end
    end
    grid.grouped_rows = groupRows(grid.full_rows)
  end
  for _, pair in ipairs({{"d6","d8"},{"d8","d10"}}) do
    local name = pair[1] .. "_" .. pair[2]
    local variant = {pool_ids=copyArray(pair), cell_format="one_handed/two_handed", full_rows=array()}
    f.versatile[name] = variant
    for index, first in ipairs(f.grids[pair[1]].full_rows) do
      local second = f.grids[pair[2]].full_rows[index]
      local row = {r=first.r, label=first.label, totals=array()}
      for a=1,#armorIds do
        if first.totals[a] == NULL then assert(second.totals[a] == NULL); row.totals[a] = NULL
        else row.totals[a] = array({first.totals[a],second.totals[a]}) end
      end
      variant.full_rows[#variant.full_rows+1] = row
    end
    variant.grouped_rows = groupRows(variant.full_rows)
  end
  -- Check the continuation formula beyond every printed column, not only at
  -- R=35. These checks exercise the actual engine and do not clamp the tail.
  for _, armor in ipairs(armorIds) do
    for _, poolId in ipairs(poolIds) do
      if poolId ~= "fixed1" then
        local first = assert(Engine.resolve({natural=10, attack_bonus=45, defense=0, weapon=family.id, armor=armor}))
        local second = assert(Engine.resolve({natural=10, attack_bonus=65, defense=0, weapon=family.id, armor=armor}))
        local a = assert(Engine.damageOverflow(poolSpecs[poolId],first.overflow))
        local b = assert(Engine.damageOverflow(poolSpecs[poolId],second.overflow))
        assert(b-a == 2*export.pools[poolId].mu, "unprinted tail must increase by two means for another twenty")
        export.validation.high_tail_checks = export.validation.high_tail_checks + 1
      end
    end
  end
end

for _, chain in ipairs({{20,1},{20,10},{20,20,10},{20,20,20,10}}) do
  local attack = assert(Engine.resolve({natural=20,open_roll=chain,attack_bonus=5,defense=0,weapon="bladed",armor="plate"}))
  local example = {family="bladed",armor="plate",open_roll=copyArray(chain),attack_bonus=5,defense=0,
    roll_total=attack.roll_total,r=attack.roll_total+5,index=attack.index,critical=attack.critical,
    r0=attack.overflow_start/5,overflow_d20=attack.overflow,supplements={}}
  for _, poolId in ipairs({"d8","2d6"}) do example.supplements[poolId] = assert(Engine.damageOverflow(poolSpecs[poolId],attack.overflow)) end
  export.examples[#export.examples+1] = example
end
assert(export.validation.lookup_points == 8*7*36)
assert(export.validation.grouped_range_checks == 8*9*36)
assert(export.validation.high_tail_checks == 8*7*6)
local encoded = json(export,0) .. "\n"
local temporaryPath = outputPath .. ".tmp"
local file = assert(io.open(temporaryPath,"wb"))
assert(file:write(encoded)); assert(file:close())
assert(os.rename(temporaryPath,outputPath))
print("Exported " .. outputPath .. " (" .. #encoded .. " bytes), engine " .. Engine.getVersion())
print("Checks: " .. export.validation.lookup_points .. " table lookups; " .. export.validation.engine_damage_calls
  .. " ArmsEngine damage evaluations; " .. export.validation.grouped_range_checks .. " grouped rows; "
  .. export.validation.high_tail_checks .. " unprinted tail continuations.")
for _, id in ipairs(export.family_order) do
  local counts = {}
  for _, poolId in ipairs(poolIds) do counts[#counts+1] = poolId .. "=" .. #export.families[id].grids[poolId].grouped_rows end
  for _, name in ipairs({"d6_d8","d8_d10"}) do counts[#counts+1] = name .. "=" .. #export.families[id].versatile[name].grouped_rows end
  print(id .. ": " .. table.concat(counts, ", "))
end
