# Balance de ocho familias y siete perfiles con d20 abierto

**Arms Bridge 0.3.1 incluye ocho familias y tres perfiles de protección natural, conservando el d20 abierto y la continuación del daño de 0.2.0.** Esta revisión corrige una pérdida de precisión al acumular probabilidades, sin modificar las curvas. El análisis cubre **504 escenarios**. Con la ponderación actual de 56 parejas, el daño medio queda un **1,04 %** por encima de D&D con ataque `+5` normal, y un **41,62 %** por encima con `+13` y ventaja. Cambiar el catálogo y el peso de las muestras no supone una mejora de calibración: se incluye un control con las mismas parejas de 0.2.0 para separar esa ponderación de la pequeña corrección numérica. Todas las curvas siguen siendo datos originales de demostración.

## 1. Familias, protección natural y atributos separados

Las ocho familias tienen identificadores canónicos propios. La tabla indica las curvas utilizadas como punto de partida y la muestra de dados empleada en este informe; **la familia no impone esa expresión de daño a todas sus armas**. Las muestras corresponden, respectivamente, a martillo de guerra, espada larga, hacha a dos manos, lanza, arco largo, ballesta ligera, látigo y pistola, usando sus dados de [Equipment de las Basic Rules 2024](https://www.dndbeyond.com/sources/dnd/br-2024/equipment). El `+3` es una constante del análisis.

| Familia | ID | Curva inicial de demostración | Muestra de daño |
|---|---|---|---:|
| Blunted weapons | `blunted` | Curva anterior `mace` | `1d8+3` |
| Bladed weapons | `bladed` | Curva anterior `sword` | `1d8+3` |
| Axes | `axes` | Curva anterior `axe` | `1d12+3` |
| Pole arms | `polearms` | Curva anterior `spear` | `1d6+3` |
| Bows | `bows` | Curva anterior `bow` | `1d8+3` |
| Crossbows | `crossbows` | Copia inicial de `bows` | `1d8+3` |
| Exotic | `exotic` | Copia inicial de `bladed` | `1d4+3` |
| Firearms | `firearms` | Copia inicial de `bows` | `1d10+3` |

Las cinco curvas anteriores mantienen sus valores. Las tres familias añadidas tienen registros propios, aunque sus formas iniciales coincidan con otras familias. No se han inventado ventajas de penetración para ballestas o armas de fuego ni se afirma que estas copias reproduzcan una tabla de Arms Law. **Simple/Martial y uso real con una o dos manos son atributos separados**: no añaden aquí un multiplicador ni un bonus de daño. El motor utiliza los dados nativos que correspondan al arma y su uso; una tabla personalizada por uso sería una elección explícita adicional.

Se conservan `unarmored`, `leather`, `mail` y `plate`, y se añaden estos perfiles naturales. Sus filas son copias independientes que pueden sustituirse mediante una tabla personalizada; coincidir como punto de partida no constituye una equivalencia oficial entre protección natural y armaduras fabricadas.

| Perfil | Significado de la asignación | Curva inicial |
|---|---|---|
| `unarmored` | Ausencia de protección material o natural | Curva previa sin armadura |
| `natural_hide` | Piel dura natural | Copia de `leather` |
| `natural_scales` | Escamas | Copia de `mail` |
| `natural_shell` | Caparazón | Copia de `plate` |

La ausencia de armadura equipada no determina si una criatura tiene piel dura o escamas. El perfil natural debe asignarse explícitamente; **no se deduce a partir de la AC del monstruo**, y `unarmored` no se interpreta como `natural_hide`. Los nombres antiguos `mace`, `sword`, `axe`, `spear` y `bow` actúan como alias exactos de los cinco IDs canónicos correspondientes. Un CSV que use ambos nombres de una misma familia se rechaza por ambigüedad; entre importaciones distintas, la última sustituye la tabla canónica completa en orden cronológico. No se conservan dos curvas independientes bajo, por ejemplo, `sword` y `bladed`. Los nombres personalizados con sufijos, como `sword_1h`, no se convierten por prefijo.

## 2. Regla de ataque y daño

La tabla de familia de armas y tipo de armadura devuelve impacto y calidad `q` entre 0 y 1. Para un impacto no crítico, la calidad selecciona un percentil de la distribución de la **suma de los dados base del arma concreta**: `1d12` y `2d6` conservan distribuciones distintas, aunque compartan tabla. En el percentil 75 dan 9 ambos; en el percentil 90 dan 11 y 10. Los modificadores fijos se mantienen aparte y se añaden una vez. Esta parte del modelo conserva los valores legales de cada dado; el daño que excede la tabla se expresa mediante un suplemento.

La selección utiliza el menor resultado cuya probabilidad acumulada alcanza `q`. En 0.3.0, la suma sucesiva de probabilidades de `d12` podía quedar apenas por debajo de `0,5` y seleccionar 7 en lugar de 6. **0.3.1 utiliza acumulación compensada de Kahan en la normalización y en la CDF**, conservando los términos que se perdían al sumar. No añade una tolerancia ni redondea `q`: el valor representable inmediatamente superior a `0,5` sigue seleccionando 7, mientras que `0,5` y su vecino inferior seleccionan 6. Las pruebas cubren estos límites en varios dados; la exportación para las tablas impresas contrasta sus 7.236 celdas de daño con convoluciones y fracciones exactas, sin excepciones.

Sea `T` la suma del d20 seleccionado inicialmente y sus continuaciones; `B`, el bonus de ataque; `E`, la defensa adicional después de separar la protección material; e `I`, el índice entero de la tabla. Si `L` es el inicio de la última fila de la columna correspondiente y `μ` la media de los dados base del arma, la regla es:

\[
I=\left\lfloor5(T+B-E)+\text{offset}\right\rfloor,
\qquad X=\max\left(0,\frac{I-L}{5}\right),
\qquad \Delta D=\left\lfloor\frac{\mu X}{10}\right\rfloor.
\]

Un impacto no crítico causa `F⁻¹(q) + M + ΔD`, donde `M` es el modificador fijo. Cada diez puntos adicionales del d20 acumulado equivalen a una media de los dados base, redondeando el suplemento total hacia abajo. Para `1d8`, esa media es 4,5; para `2d6`, 7. La misma regla se aplica a un ataque ordinario con un índice suficientemente alto: la última fila deja de ser un techo. Los impactos pendientes de otra continuación y los fallos no producen suplemento. Si el arma solo tiene daño fijo, sin dados base, el suplemento es cero.

El 20 inicial conserva **un único crítico de D&D**. Sus dados de daño se procesan de forma nativa y el suplemento se suma una vez; no se maximiza además el dado base ni se vuelve a duplicar el daño por cada 20 posterior. Los veintes posteriores solo elevan el resultado acumulado. Un 1 de continuación suma uno y termina la apertura; no convierte el 20 inicial en pifia. Un crítico obtenido mediante un rango ampliado, como un 19, sigue siendo crítico nativo, pero no abre el d20 por esa sola razón. El suplemento crece de forma monótona para los mismos dados de daño; dos tiradas críticas independientes siguen teniendo variación aleatoria.

## 3. Qué significa seguir aumentando el daño

En la tabla original de demostración `bladed/plate`, con ataque `+5` y defensa adicional `E 0`, la última fila comienza en `I 130`. Los siguientes resultados usan esa misma columna para dos expresiones de daño distintas. Las cifras de las dos últimas columnas son **suplementos**, que se añaden a los dados críticos nativos y al modificador fijo; no representan el daño completo.

| Tirada abierta | Suma `T` | Índice `I` | Exceso `X` | Suplemento `1d8` | Suplemento `2d6` |
|---|---:|---:|---:|---:|---:|
| 20 + 1 | 21 | 130 | 0 | 0 | 0 |
| 20 + 10 | 30 | 175 | 9 | 4 | 6 |
| 20 + 19 | 39 | 220 | 18 | 8 | 12 |
| 20 + 20 + 10 | 50 | 275 | 29 | 13 | 20 |
| 20 + 20 + 20 + 10 | 70 | 375 | 49 | 22 | 34 |

Una secuencia `20 + 20` todavía necesita otro d20; no se liquida como resultado final 40. Una vez superado el inicio de la cola, cada 20 adicional añade exactamente `2μ` al suplemento: 9 puntos con `1d8` y 14 con `2d6`. Puede repetirse sin un límite establecido por la regla. La implementación comprueba que las cifras se puedan representar con precisión numérica y comunica un error si no es así; no recorta silenciosamente el daño a un máximo.

En este ejemplo, condicionado a haber sacado el 20 inicial, el suplemento medio exacto es `77/19 = 4,052632` con `1d8` y `125/19 = 6,578947` con `2d6`. Por tanto, el crítico abierto de `1d8+3` tiene media **16,052632**, frente a 12 en D&D; el de `2d6+3` tiene media **23,578947**, frente a 17. En tiradas normales, esos suplementos aportan respectivamente **0,202632 y 0,328947 puntos por intento**, porque solo el 5 % de los intentos comienza con 20. Son cifras de esta pareja y bonificación concretas; otras columnas alcanzan su última fila en otro punto.

## 4. Cómo se ha evaluado una cola infinita

[`tools/analyze.lua`](../tools/analyze.lua) carga el motor Lua `0.3.1` y evalúa **504 escenarios**: ocho familias, siete perfiles, ataques `+5/+9/+13` y tiradas normales, con ventaja y con desventaja. Enumera los 20 resultados iniciales o los 400 pares posibles. Ventaja y desventaja afectan solo a la selección inicial; las continuaciones son d20 ordinarios. La probabilidad de abrir es así `5 %`, `9,75 %` o `0,25 %`. Cada continuación vuelve a abrir con probabilidad `1/20`, independientemente de cómo se seleccionó el primer dado.

La suma `S` de una continuación abierta toma valores `20k+r`, con `k ≥ 0`, `r ∈ {1,…,19}` y probabilidad `20⁻⁽ᵏ⁺¹⁾`. Su media es `210/19 = 11,052632`; después de un primer 20, el total de ataque medio es por tanto `31,052632`. En tiradas normales, empezar con dos veintes tiene probabilidad `0,25 %`, y con tres veintes, `0,0125 %`. La cola es ilimitada, pero estas probabilidades decrecen geométricamente mientras el suplemento crece linealmente; su esperanza es finita.

El analizador **no corta la cadena después de cierto número de veintes**. En los escenarios de demostración, `20+20+r` ya está por encima del comienzo de la última fila. Si `p=1/20`, `Cᵣ(0)` es el daño medio de `20+r` y `Cᵣ(1)` el de `20+20+r`, incluyendo el crítico nativo y el suplemento, la media condicional a un primer 20 se obtiene mediante:

\[
\mathbb{E}[D\mid\text{primer 20}]=
\sum_{r=1}^{19}\left[
pC_r(0)+\frac{p^2}{1-p}C_r(1)+\frac{p^3}{(1-p)^2}\,2\mu
\right].
\]

El término final suma todos los incrementos de los veintes posteriores. El analizador comprueba en el motor el incremento `2μ` y contrasta las medias de `1d8` y `2d6` con las formas cerradas anteriores. El cálculo es determinista y usa aritmética de coma flotante; no utiliza muestreo aleatorio. Esta suma está validada para los perfiles y bonificaciones incluidos: el propio análisis falla si su ancla de dos veintes no ha alcanzado la cola de una tabla modificada.

Las defensas originales son: sin armadura `AC 13/E 3`, cuero tachonado `AC 15/E 3`, malla `AC 16/E 0` y placas `AC 18/E 0`. Los tres defensores naturales son **casos ficticios de comparación asignados expresamente**: piel dura `AC 15/E 3`, escamas `AC 16/E 0` y caparazón `AC 18/E 0`. Estos valores permiten comparar cada copia con su curva inicial; no son una clasificación de monstruos ni una asignación automática de protección a partir de la AC. El analizador verifica las 216 igualdades entre perfiles naturales y sus puntos de partida a través de familias, bonus y modos.

Los dados de las ocho muestras figuran en la primera tabla y mantienen `+3` para aislar el bonus de ataque. El ejemplo adicional de `2d6` valida la cola de un arma con varios dados, pero no añade otra muestra a las 504 comparaciones. Las reglas de referencia son las [Basic Rules 2024](https://www.dndbeyond.com/sources/dnd/br-2024/playing-the-game). No se incluyen masteries/Graze, Sneak Attack, Smite, resistencias, recursos ni ataques adicionales; tampoco rangos críticos ampliados en las comparaciones numéricas. El análisis mide un intento individual y no efectos como Loading sobre la cantidad de ataques por turno.

## 5. Resultados frente a D&D

Cada celda de esta matriz muestra **Bridge / D&D**, como daño esperado **por intento**, incluyendo fallos y críticos. Corresponde a ataque `+5` con tiradas normales. La referencia nativa es `P(impacto) × (μ + M) + P(crítico) × μ`; la probabilidad de impacto ya incluye los críticos.

| Familia y muestra | Sin armadura | Cuero tachonado | Malla | Placas |
|---|---:|---:|---:|---:|
| Blunted weapons, `1d8+3` | 4,36 / 5,10 | 4,04 / 4,35 | 4,72 / 3,98 | 4,60 / 3,23 |
| Bladed weapons, `1d8+3` | 4,88 / 5,10 | 4,56 / 4,35 | 4,15 / 3,98 | 3,45 / 3,23 |
| Axes, `1d12+3` | 7,00 / 6,50 | 6,57 / 5,55 | 4,57 / 5,08 | 3,77 / 4,12 |
| Pole arms, `1d6+3` | 4,24 / 4,40 | 4,54 / 3,75 | 4,07 / 3,43 | 3,47 / 2,77 |
| Bows, `1d8+3` | 4,88 / 5,10 | 4,56 / 4,35 | 3,58 / 3,98 | 2,41 / 3,23 |
| Crossbows, `1d8+3` | 4,88 / 5,10 | 4,56 / 4,35 | 3,58 / 3,98 | 2,41 / 3,23 |
| Exotic, `1d4+3` | 3,60 / 3,70 | 3,34 / 3,15 | 2,96 / 2,87 | 2,36 / 2,32 |
| Firearms, `1d10+3` | 5,43 / 5,80 | 5,10 / 4,95 | 4,13 / 4,52 | 2,80 / 3,67 |

La matriz muestra las cuatro defensas originales. Los tres perfiles naturales producen las mismas medias que las columnas que les sirven de punto de partida, bajo los defensores ficticios del análisis; sus columnas también aparecen en la salida completa del analizador. El promedio de las **56 parejas**, todas con el mismo peso, es **4,0703 frente a 4,0286: +1,04 %**. Incluye coincidencias de curvas y no representa 56 comportamientos independientes ni la frecuencia de armas y enemigos de una campaña.

Ese promedio próximo a D&D oculta diferencias tácticas grandes: el martillo de guerra contra placas aumenta un **42,6 %** y el arco largo contra placas disminuye un **25,2 %**. La probabilidad de impacto de la espada larga contra placas sigue siendo `40 %`; el martillo de guerra contra placas tiene `50 %` frente al `40 %` nativo. Las aperturas no añaden otra probabilidad de crítico a la del 20 inicial. Los porcentajes se calculan antes de redondear las celdas de la matriz. Esta tabla compara el daño esperado medio de las 56 parejas al variar bonus y selección inicial del d20:

| Bonificación al ataque | Normal | Ventaja | Desventaja |
|---:|---:|---:|---:|
| +5 | +1,04 % | +5,72 % | −13,23 % |
| +9 | +14,43 % | +23,70 % | −3,19 % |
| +13 | +25,80 % | +41,62 % | +5,25 % |

Con `+13` y ventaja, las medias son **11,0796 frente a 7,8236** por intento. La mayor desviación individual sigue siendo **+61,01 %**, alcanzada por `blunted/plate` con `+13` y ventaja; la mayor caída es **−53,30 %**, alcanzada por `bows/plate` con `+5` y desventaja. Las copias naturales equivalentes pueden compartir estos extremos. El analizador imprime también la matriz completa de `+5` con ventaja y exporta todas las celdas con una columna separada para el suplemento esperado.

El control con **las mismas cinco familias, dados y cuatro defensas de 0.2.0** da ahora **4,4225 / 4,2775 (+3,39 %)** con `+5` normal y **11,6295 / 8,0524 (+44,42 %)** con `+13` y ventaja. Antes de corregir la acumulación numérica eran `4,4275` y `11,6320`, respectivamente, para Bridge. Esa diferencia pequeña procede del percentil de `d12`; no de una recalibración de curvas o de la cola. La diferencia mayor entre este control y el agregado de 56 parejas procede de la mezcla de familias, expresiones de daño y perfiles con otro peso.

## 6. Decisiones de calibración pendientes

**La bonificación al ataque mejora a la vez la probabilidad de acertar, el percentil de daño y el exceso sobre la tabla.** Ventaja refuerza esos efectos y casi duplica la frecuencia de apertura frente al d20 normal. Eliminar el techo hace visible esta tercera fuente de crecimiento. Las cifras conservan magnitudes propias del daño del arma, pero no acreditan equivalencia de balance: el `+41,62 %` agregado con `+13` y ventaja necesita revisión antes de tratar estas curvas como reglas terminadas. La pendiente de una media de dados por diez puntos sigue siendo una decisión experimental, no un valor deducido de Arms Law ni un ajuste óptimo demostrado.

**Las diferencias entre armas y materiales también necesitan revisión por separado.** La muestra de `blunted` contra placas recibe más daño esperado que contra cuero tachonado en las nueve combinaciones de bonificación y selección del d20. Con `+5` normal, son `4,5974` frente a `4,0442`, un `13,68 %` más; esos perfiles tienen evasión distinta (`E 0` y `E 3`), por lo que la comparación incluye al defensor completo. Con `+13` y ventaja aparecen también pequeñas inversiones para `bladed` (`1,71 %`) y `polearms` (`2,13 %`). Promediando las ocho muestras, placas sigue recibiendo menos daño que cuero en los nueve escenarios. El promedio global no decide si esas diferencias concretas son deseadas.

La conversión por percentiles recuperaría la distribución original si `q` fuera uniforme; las bandas de ataque no garantizan esa condición. Conviene calibrar las curvas y su pendiente conjuntamente, midiendo daño por intento en varias bonificaciones, modos de tirada y distribuciones de arma. Las familias y los perfiles nuevos permiten sustituir sus curvas de manera independiente, sin haber establecido todavía diferencias nuevas de penetración o protección. **Son datos originales de demostración, no tablas transcritas de ICE**. No se han añadido críticos, heridas ni estados propios de Rolemaster.

Para reproducir los resultados desde la raíz del proyecto, ejecutar `lua tools/analyze.lua`, o `python3 tools/test.py --require-lua --test tools/analyze.lua` mediante el ejecutor de pruebas. `lua tools/analyze.lua --csv` imprime las 504 celdas y el suplemento esperado de cada una. Este informe valida la aritmética del modelo y su cola infinita; las interacciones de personajes completos y la ejecución dentro de Fantasy Grounds requieren sus pruebas correspondientes.
