-- Finite enumeration plus exact geometric summation of the unbounded tail.
-- Uses the real ArmsEngine; no simulation or artificial maximum open result.
-- Run from the project root: lua tools/analyze.lua
-- Alternative with the bundled runtime discovery:
-- python3 tools/test.py --require-lua --test tools/analyze.lua
-- A standalone Lua invocation can add --csv for every individual result.

local Engine = dofile("extension/scripts/arms_engine.lua")
local bonuses = { 5, 9, 13 }
local modes = {
  { id = "normal", label = "Normal" },
  { id = "advantage", label = "Ventaja" },
  { id = "disadvantage", label = "Desventaja" },
}
local armors = {
  { id = "unarmored", label = "Sin armadura", ac = 13, defense = 3 },
  { id = "leather", label = "Cuero tachonado", ac = 15, defense = 3 },
  { id = "mail", label = "Malla", ac = 16, defense = 0 },
  { id = "plate", label = "Placas", ac = 18, defense = 0 },
  -- Explicit synthetic defenders for comparisons, not AC-based creature
  -- classification or asserted natural/material armor equivalences.
  { id = "natural_hide", label = "Piel dura", ac = 15, defense = 3, seed = "leather" },
  { id = "natural_scales", label = "Escamas", ac = 16, defense = 0, seed = "mail" },
  { id = "natural_shell", label = "Caparazón", ac = 18, defense = 0, seed = "plate" },
}
local weapons = {
  { id = "blunted", label = "Blunted weapons", dice = { 8 }, modifier = 3 },
  { id = "bladed", label = "Bladed weapons", dice = { 8 }, modifier = 3 },
  { id = "axes", label = "Axes", dice = { 12 }, modifier = 3 },
  { id = "polearms", label = "Pole arms", dice = { 6 }, modifier = 3 },
  { id = "bows", label = "Bows", dice = { 8 }, modifier = 3 },
  { id = "crossbows", label = "Crossbows", dice = { 8 }, modifier = 3 },
  { id = "exotic", label = "Exotic", dice = { 4 }, modifier = 3 },
  { id = "firearms", label = "Firearms", dice = { 10 }, modifier = 3 },
}

local function sum(values)
  local value = 0
  for _, item in ipairs(values) do value = value + item end
  return value
end

local function expectedDice(dice)
  local value = 0
  for _, sides in ipairs(dice) do value = value + (sides + 1) / 2 end
  return value
end

local function enumerate(mode, callback)
  if mode == "normal" then
    for natural = 1, 20 do callback(natural, 1 / 20) end
  else
    for first = 1, 20 do
      for second = 1, 20 do
        local natural
        if mode == "advantage" then natural = math.max(first, second)
        else natural = math.min(first, second) end
        callback(natural, 1 / 400)
      end
    end
  end
end

-- Conditional on the selected initial d20 being 20. For the demo tables,
-- 20+20+1 already exceeds the last row. Each further 20 raises the extra by
-- exactly 2*meanDice: the floor commutes with this INTEGER increment, including
-- mixed and multidie pools. Sum every remaining chain with geometric series.
local function expectedOpenDamage(weapon, armor, bonus, diceMean)
  local probability, expectation = 1/20, 0
  local nativeCritical = 2*diceMean + weapon.modifier
  local step = 2*diceMean
  assert(step % 1 == 0, "tail increment must be an integer for ordinary dice")
  for last = 1,19 do
    local first = assert(Engine.resolve({natural=20, open_roll={20,last}, attack_bonus=bonus,
      defense=armor.defense, weapon=weapon.id, armor=armor.id}))
    local second = assert(Engine.resolve({natural=20, open_roll={20,20,last}, attack_bonus=bonus,
      defense=armor.defense, weapon=weapon.id, armor=armor.id}))
    local third = assert(Engine.resolve({natural=20, open_roll={20,20,20,last}, attack_bonus=bonus,
      defense=armor.defense, weapon=weapon.id, armor=armor.id}))
    assert(not first.needs_open and second.overflow > 0, "demo tail must be beyond the table by two twenties")
    local extraFirst = assert(Engine.damageOverflow(weapon.dice, first.overflow))
    local extraSecond = assert(Engine.damageOverflow(weapon.dice, second.overflow))
    local extraThird = assert(Engine.damageOverflow(weapon.dice, third.overflow))
    assert(extraThird-extraSecond==step, "engine must match the analytical tail increment")
    expectation = expectation + probability*(nativeCritical+extraFirst)
      + probability^2/(1-probability)*(nativeCritical+extraSecond)
      + probability^3/(1-probability)^2*step
  end
  return expectation
end

-- Independent closed forms at bladed/plate,+5,E0: overflow after an initial 20
-- is max(0,S-1), where S is an exploding d20. The nineteen final faces give
-- sums of 68 and 111 points of extra damage before repeat-twenty blocks; every
-- extra block adds 9 or 14. Thus E[extra] is 77/19 or 125/19 respectively.
local criticalEight = expectedOpenDamage(weapons[2], armors[4], 5, 4.5)
local multiDiceWeapon = { id = "bladed", dice = {6,6}, modifier = 3 }
local criticalSixes = expectedOpenDamage(multiDiceWeapon, armors[4], 5, 7)
assert(math.abs(criticalEight - (12 + 77/19)) < 1e-10, "1d8 infinite tail must match its closed form")
assert(math.abs(criticalSixes - (17 + 125/19)) < 1e-10, "2d6 infinite tail must match its closed form")

local function evaluate(weapon, armor, bonus, mode)
  local result = {
    weapon = weapon.id, armor = armor.id, bonus = bonus, mode = mode,
    bridge = 0, native = 0, bridge_hits = 0, native_hits = 0,
    bridge_crits = 0, native_crits = 0, probability = 0, overflow_damage = 0,
  }
  local diceMean = expectedDice(weapon.dice)
  local criticalMean = expectedOpenDamage(weapon, armor, bonus, diceMean)
  enumerate(mode, function(natural, probability)
    result.probability = result.probability + probability
    local attack, message = Engine.resolve({
      natural = natural, attack_bonus = bonus, defense = armor.defense,
      weapon = weapon.id, armor = armor.id,
    })
    assert(attack, message)
    if attack.hit then
      local damage
      if attack.critical then
        damage = criticalMean
        result.overflow_damage = result.overflow_damage + probability*(criticalMean-2*diceMean-weapon.modifier)
        result.bridge_crits = result.bridge_crits + probability
      else
        local dice, diceError = Engine.damageDice(weapon.dice, attack.quality)
        assert(dice, diceError)
        local extra = assert(Engine.damageOverflow(weapon.dice, attack.overflow))
        damage = sum(dice) + weapon.modifier + extra
        result.overflow_damage = result.overflow_damage + probability*extra
      end
      result.bridge = result.bridge + probability * damage
      result.bridge_hits = result.bridge_hits + probability
    end
    local nativeHit = natural == 20 or (natural ~= 1 and natural + bonus >= armor.ac)
    if nativeHit then
      local damage = diceMean + weapon.modifier
      if natural == 20 then
        damage = damage + diceMean
        result.native_crits = result.native_crits + probability
      end
      result.native = result.native + probability * damage
      result.native_hits = result.native_hits + probability
    end
  end)
  assert(math.abs(result.probability - 1) < 0.0000001, "enumeration probability must sum to one")
  assert(math.abs(result.bridge_crits - result.native_crits) < 0.0000001, "native critical frequency must be preserved")
  return result
end

local cells, lookup = {}, {}
local function key(bonus, mode, weapon, armor)
  return bonus .. ":" .. mode .. ":" .. weapon .. ":" .. armor
end
for _, bonus in ipairs(bonuses) do
  for _, mode in ipairs(modes) do
    for _, weapon in ipairs(weapons) do
      for _, armor in ipairs(armors) do
        local cell = evaluate(weapon, armor, bonus, mode.id)
        cells[#cells + 1] = cell
        lookup[key(bonus, mode.id, weapon.id, armor.id)] = cell
      end
    end
  end
end

local function get(bonus, mode, weapon, armor)
  return assert(lookup[key(bonus, mode, weapon, armor)])
end

-- These equalities are declared demo seeds. Checking all contexts prevents
-- a copied natural label from silently acquiring a different curve or E.
for _, bonus in ipairs(bonuses) do
  for _, mode in ipairs(modes) do
    for _, weapon in ipairs(weapons) do
      for _, armor in ipairs(armors) do
        if armor.seed then
          local natural = get(bonus, mode.id, weapon.id, armor.id)
          local seed = get(bonus, mode.id, weapon.id, armor.seed)
          assert(math.abs(natural.bridge - seed.bridge) < 1e-10, "natural demo result must match its declared seed")
          assert(math.abs(natural.native - seed.native) < 1e-10, "natural comparison fixture must match its declared seed")
        end
      end
    end
  end
end

local function average(bonus, mode)
  local bridge, native, count = 0, 0, 0
  for _, weapon in ipairs(weapons) do
    for _, armor in ipairs(armors) do
      local cell = get(bonus, mode, weapon.id, armor.id)
      bridge, native, count = bridge + cell.bridge, native + cell.native, count + 1
    end
  end
  return bridge / count, native / count
end

-- A fixed comparison set keeps changes of catalog weighting separate from
-- changes to the previous five curves and open-roll formula.
local function previousAverage(bonus, mode)
  local bridge, native, count = 0, 0, 0
  for _, family in ipairs({"bladed","blunted","polearms","axes","bows"}) do
    for _, armor in ipairs({"unarmored","leather","mail","plate"}) do
      local cell = get(bonus, mode, family, armor)
      bridge, native, count = bridge + cell.bridge, native + cell.native, count + 1
    end
  end
  return bridge / count, native / count
end

local function delta(bridge, native)
  return 100 * (bridge / native - 1)
end

local function printMatrix(bonus, mode, label)
  print("## Ataque +" .. bonus .. ": " .. label)
  print("")
  print("Daño esperado por intento: **Bridge / D&D (diferencia relativa)**.")
  print("")
  local heading, alignment = {"Familia"}, {"---"}
  for _, armor in ipairs(armors) do heading[#heading+1] = armor.label; alignment[#alignment+1] = "---:" end
  print("| " .. table.concat(heading," | ") .. " |")
  print("|" .. table.concat(alignment,"|") .. "|")
  for _, weapon in ipairs(weapons) do
    local row = { weapon.label }
    for _, armor in ipairs(armors) do
      local cell = get(bonus, mode, weapon.id, armor.id)
      row[#row + 1] = string.format("%.2f / %.2f (%+.1f%%)", cell.bridge, cell.native, delta(cell.bridge, cell.native))
    end
    print("| " .. table.concat(row, " | ") .. " |")
  end
  print("")
end

local asCSV = false
for _, argument in ipairs(type(arg) == "table" and arg or {}) do
  if argument == "--csv" then asCSV = true end
end
if asCSV then
  print("attack_bonus,mode,weapon,armor,bridge_damage,native_damage,relative_delta_pct,bridge_hit_probability,native_hit_probability,critical_probability,expected_overflow_damage")
  for _, cell in ipairs(cells) do
    print(string.format("%d,%s,%s,%s,%.10f,%.10f,%.10f,%.10f,%.10f,%.10f,%.10f",
      cell.bonus, cell.mode, cell.weapon, cell.armor, cell.bridge, cell.native,
      delta(cell.bridge, cell.native), cell.bridge_hits, cell.native_hits, cell.bridge_crits, cell.overflow_damage))
  end
else
  print("# Análisis de las curvas originales con d20 abierto")
  print("")
  print("Motor " .. Engine.getVersion() .. "; " .. #cells .. " escenarios: ocho familias por siete perfiles, tres bonus y tres modos. 20 resultados iniciales equiprobables en normal y 400 pares en ventaja/desventaja; cola infinita sumada mediante series geométricas. Sin simulación aleatoria ni truncamiento del daño.")
  print("Las curvas son datos originales experimentales: no contienen tablas de Arms Law y no están calibradas como reglas equilibradas de D&D.")
  print("El motor 0.3.1 corrige la acumulación numérica de probabilidades: el percentil 50 de d12 es 6, y un percentil inmediatamente superior conserva el resultado 7. No se han cambiado curvas ni la fórmula de la cola.")
  print("")
  print("Defensas: sin armadura AC13/E3; cuero tachonado AC15/E3; malla AC16/E0; placas AC18/E0.")
  print("Defensores naturales sintéticos y asignados explícitamente: piel dura AC15/E3, escamas AC16/E0, caparazón AC18/E0. No se deduce el perfil natural de la AC.")
  print("Semillas de demostración: crossbows/firearms copian la curva bows y exotic copia bladed; natural_hide/scales/shell copian leather/mail/plate, en filas independientes y reemplazables.")
  print("Dados de ejemplo: blunted=1d8+3, bladed=1d8+3, axes=1d12+3, polearms=1d6+3, bows=1d8+3, crossbows=1d8+3, exotic=1d4+3, firearms=1d10+3. La familia no fija los dados de otras armas. El modificador +3 se mantiene fijo para aislar el bonus de ataque.")
  print("Categoría simple/martial y uso real con una/dos manos son atributos separados; no aportan un bonus de daño adicional en este análisis ni en el motor. Los dados nativos ya reflejan el arma y su uso.")
  print("El crítico conserva los dados nativos: dos veces la media de los dados, +3; Bridge añade una sola vez el suplemento por exceso. La base del crítico no se maximiza.")
  print("Un 20 inicial abre la tirada; solo los 20 siguientes continúan. Ventaja/desventaja afectan a la selección inicial, las continuaciones son d20 simples.")
  print("En impactos no críticos se aplica el percentil de los dados propios del arma. En cualquier impacto que supere la última fila se añade floor(mediaDados * excesoD20 / 10); el modificador fijo se suma una sola vez.")
  print("No se incluyen masteries/Graze, rasgos de clase, resistencias ni recursos. Cada cifra es por intento, no por impacto ni por turno.")
  print("")
  printMatrix(5, "normal", "Normal")
  printMatrix(5, "advantage", "Ventaja")
  print("## Promedio de las 56 parejas familia/perfil")
  print("")
  print("Todas las parejas tienen el mismo peso. Incluye semillas coincidentes y muestras de arma distintas: no es una muestra de 56 comportamientos independientes ni representa una campaña. La ponderación ha cambiado respecto a las veinte parejas de 0.2.0.")
  print("")
  print("| Ataque | Modo | Bridge | D&D | Diferencia |")
  print("|---:|---|---:|---:|---:|")
  for _, bonus in ipairs(bonuses) do
    for _, mode in ipairs(modes) do
      local bridge, native = average(bonus, mode.id)
      print(string.format("| +%d | %s | %.4f | %.4f | %+.2f%% |", bonus, mode.label, bridge, native, delta(bridge, native)))
    end
  end
  local previousNormal, previousNativeNormal = previousAverage(5,"normal")
  local previousAdvantage, previousNativeAdvantage = previousAverage(13,"advantage")
  print("")
  print(string.format("Control con las mismas cinco familias y cuatro defensas de 0.2.0: +5 normal %.4f / %.4f (%+.2f%%); +13 con ventaja %.4f / %.4f (%+.2f%%). Las curvas anteriores y la fórmula abierta no se han recalibrado; se aplica la corrección de precisión numérica de 0.3.1.",
    previousNormal, previousNativeNormal, delta(previousNormal,previousNativeNormal),
    previousAdvantage, previousNativeAdvantage, delta(previousAdvantage,previousNativeAdvantage)))
  print("")
  print("## Probabilidad de impacto con +5, sin ventaja")
  print("")
  print("Cada celda indica Bridge / D&D. Incluye el natural20 automático y excluye el natural1.")
  print("")
  local hitHeading, hitAlignment = {"Familia"}, {"---"}
  for _, armor in ipairs(armors) do hitHeading[#hitHeading+1] = armor.label; hitAlignment[#hitAlignment+1] = "---:" end
  print("| " .. table.concat(hitHeading," | ") .. " |")
  print("|" .. table.concat(hitAlignment,"|") .. "|")
  for _, weapon in ipairs(weapons) do
    local row = { weapon.label }
    for _, armor in ipairs(armors) do
      local cell = get(5, "normal", weapon.id, armor.id)
      row[#row + 1] = string.format("%.0f%% / %.0f%%", 100 * cell.bridge_hits, 100 * cell.native_hits)
    end
    print("| " .. table.concat(row, " | ") .. " |")
  end
  print("")
  print("Críticos: 5% en normal, 9.75% con ventaja y 0.25% con desventaja, iguales en ambos modelos. Un índice alto sin natural20 no crea un crítico.")
  print("")
  print("## Ejemplos de apertura: bladed/plate, ataque+5, defensa adicional0")
  print("")
  print("| Cadena | Suma | Índice | Extra 1d8 | Extra 2d6 |")
  print("|---|---:|---:|---:|---:|")
  for _, chain in ipairs({{20,1},{20,10},{20,19},{20,20,10},{20,20,20,10}}) do
    local attack = assert(Engine.resolve({natural=20,open_roll=chain,attack_bonus=5,defense=0,weapon="bladed",armor="plate"}))
    print(string.format("| %s | %d | %d | %d | %d |",table.concat(chain,"+"),attack.roll_total,attack.index,
      assert(Engine.damageOverflow({8},attack.overflow)),assert(Engine.damageOverflow({6,6},attack.overflow))))
  end
  print("")
  print("Los dados críticos siguen siendo nativos. El modificador y el suplemento se suman una vez cada uno. Para bladed/plate con ataque +5 y E0, el crítico abierto tiene media "
    .. string.format("%.6f",criticalEight).." con 1d8+3, frente a 12 en D&D; con 2d6+3, "
    .. string.format("%.6f",criticalSixes).." frente a 17. Son medias condicionadas a un crítico, no daño por intento.")
  print("")
  print("## Inversiones de protección y extremos")
  print("")
  local globalInversions = 0
  local smallestGlobalGap
  for _, bonus in ipairs(bonuses) do
    for _, mode in ipairs(modes) do
      local leather, plate = 0, 0
      for _, weapon in ipairs(weapons) do
        leather = leather + get(bonus, mode.id, weapon.id, "leather").bridge / #weapons
        plate = plate + get(bonus, mode.id, weapon.id, "plate").bridge / #weapons
      end
      local gap = leather - plate
      if not smallestGlobalGap or gap < smallestGlobalGap then smallestGlobalGap = gap end
      if plate > leather + 0.0000001 then
        globalInversions = globalInversions + 1
        print(string.format("Inversión global: ataque+%d, %s, placas %.4f frente a cuero %.4f.", bonus, mode.label, plate, leather))
      end
    end
  end
  if globalInversions == 0 then
    print(string.format("Promediando las ocho muestras de arma, placas recibe menos daño que cuero tachonado en los nueve escenarios; la menor diferencia absoluta es %.4f por intento.", smallestGlobalGap))
  end
  print("")
  local inversions = 0
  for _, bonus in ipairs(bonuses) do
    for _, mode in ipairs(modes) do
      for _, weapon in ipairs(weapons) do
        local leather = get(bonus, mode.id, weapon.id, "leather")
        local plate = get(bonus, mode.id, weapon.id, "plate")
        if plate.bridge > leather.bridge + 0.0000001 then
          inversions = inversions + 1
          print(string.format("- +%d, %s, %s: placas recibe %.4f; cuero tachonado %.4f (%+.2f%%).",
            bonus, mode.label, weapon.label, plate.bridge, leather.bridge, delta(plate.bridge, leather.bridge)))
        end
      end
    end
  end
  if inversions == 0 then print("No hay ningún escenario donde placas reciba más daño esperado que cuero tachonado.") end
  local minimum, maximum = cells[1], cells[1]
  for _, cell in ipairs(cells) do
    if delta(cell.bridge, cell.native) < delta(minimum.bridge, minimum.native) then minimum = cell end
    if delta(cell.bridge, cell.native) > delta(maximum.bridge, maximum.native) then maximum = cell end
  end
  print("")
  print(string.format("Mayor caída: ataque+%d, %s, %s/%s, %.4f frente a %.4f (%+.2f%%).",
    minimum.bonus, minimum.mode, minimum.weapon, minimum.armor, minimum.bridge, minimum.native, delta(minimum.bridge, minimum.native)))
  print(string.format("Mayor aumento: ataque+%d, %s, %s/%s, %.4f frente a %.4f (%+.2f%%).",
    maximum.bonus, maximum.mode, maximum.weapon, maximum.armor, maximum.bridge, maximum.native, delta(maximum.bridge, maximum.native)))
  print("")
  print("Para todas las celdas en CSV: lua tools/analyze.lua --csv")
end
