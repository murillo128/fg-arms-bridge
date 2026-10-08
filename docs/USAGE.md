# Arms Bridge — Fantasy Grounds 5E / D&D 2024

**Versión 0.3.1 alpha.** Extensión experimental que relaciona ataque y daño mediante tablas por familia de armas y armadura, con **d20 abiertos y daño que sigue creciendo por encima del último tramo de la tabla**. Su objetivo es conservar magnitudes habituales comparables a D&D 2024, permitiendo resultados excepcionales sin techo de juego. La referencia de diseño es Arms Law de Rolemaster Classic, de ICE. El paquete incluye ocho familias, siete perfiles de protección y un catálogo de cuarenta armas. Las curvas son **originales de demostración**, no las tablas oficiales de Arms Law ni una conversión numérica validada de Rolemaster.

Esta versión conserva separados los componentes de daño por tipo, convierte la base física y deja los componentes adicionales y la aplicación de resistencias, inmunidades y vulnerabilidades al sistema nativo. Añade protección natural y registra por separado categoría simple/marcial, grupo de arma y uso a una o dos manos.

La revisión 0.3.1 corrige el redondeo al acumular probabilidades para elegir el percentil: con calidad 0,50, `1d12` devuelve 6, no 7. Se conservan las reglas y los formatos de configuración e importación.

Se han probado el motor Lua, el importador, la gestión de contexto y los contratos de integración con APIs simuladas. No se ha ejecutado esta versión dentro de Fantasy Grounds. La presencia de los callbacks que indica el diagnóstico es una comprobación de capacidades, no una certificación de compatibilidad con cada versión o con otras extensiones.

## 1. Instalación y primera prueba

1. Copia `ArmsBridge.ext` en la carpeta `extensions` del directorio de datos de Fantasy Grounds. Puedes abrir ese directorio con el botón de carpeta de su pantalla de inicio. Conserva la extensión `.ext`: no descomprimas el archivo en esa carpeta.
2. Abre una campaña de prueba del sistema **5E**, selecciona las reglas 2024 y activa **Arms Bridge — 5E Attack and Armor Tables** en las extensiones de la campaña.
3. Introduce `/arms status`. La extensión empieza en modo `compare`, que muestra el cálculo alternativo y conserva la resolución nativa.
4. Añade atacante y defensor al combat tracker. Usa un arma reconocida, como `Longsword`, o asigna explícitamente el nombre de su acción con `/arms weapon`.
5. Asigna la protección del defensor. Después selecciona **un solo objetivo**, realiza el ataque desde la ficha y realiza su daño desde la misma ficha y el mismo cliente, antes de efectuar el siguiente ataque. Si el d20 seleccionado es 20, la extensión solicita las continuaciones; cada nuevo 20 permite seguir sumando.
6. Activa `/arms mode on` para aplicar la resolución alternativa. `/arms mode off` restaura el comportamiento nativo de los callbacks sin eliminar la configuración guardada.

Por ejemplo, para una **diana de prueba** llamada `Diana`, con CA nativa 15, puedes asignar una protección material de cuero con base 12. La defensa adicional calculada será `15 − 12 = 3`:

```text
/arms armor "Diana" leather 12
/arms weapon "Longsword" bladed
/arms mode compare
```

Realiza un ataque contra esa diana y revisa el chat. Para aplicar la conversión en el siguiente ataque:

```text
/arms mode on
```

El nombre `Diana` es un ejemplo, no un PNJ creado automáticamente. Los nombres se resuelven entre las entradas del combat tracker; si hay duplicados, `/arms actors` muestra las rutas que permiten seleccionar una entrada concreta.

## 2. Qué hace esta versión

La resolución obtiene una fila con `5 × (suma de los d20 + bonificación de ataque − defensa adicional)`, más el desplazamiento de la tabla cuando lo haya. La tabla depende de la familia de armas y la columna del perfil de protección. Su resultado indica fallo o impacto y una calidad entre cero y uno. El natural inicial se conserva por separado: un 1 falla; un 20 produce un impacto crítico y abre la tirada; también se conserva la marca de crítico que ya haya establecido el sistema anfitrión por otro motivo.

**El 20 se suma y permite tirar otro d20.** Si el siguiente también es 20, se suma y se vuelve a tirar. Un resultado de 1 a 19 cierra la cadena: `20+10=30`, `20+20+10=50`, `20+1=21`. El 1 de una continuación suma uno y no convierte el ataque en una pifia. Ventaja y desventaja se resuelven sobre la tirada inicial; se abre únicamente si el dado seleccionado por Fantasy Grounds es 20. Las continuaciones son d20 simples, sin volver a aplicar la bonificación de ataque, los efectos, la ventaja ni el modificador de la bandeja.

En impactos no críticos, la calidad se traduce mediante la distribución de la **suma de los dados del componente físico base del arma**. Se elige el percentil de esa distribución y se mantiene el modificador plano. Esto conserva la diferencia entre `1d12` y `2d6`, aunque las armas compartan familia. El componente se identifica por su tipo real —contundente, perforante o cortante— y puede aparecer después de una línea elemental. Su posición entre los dados se conserva para convertir únicamente los dados adecuados.

Un arma con `1d8+3` cortante y `1d4` de fuego conserva dos componentes. La tabla convierte el `1d8`; el `+3` se suma una vez y el fuego conserva sus dados y modificadores nativos. El mismo tratamiento sirve para ácido, frío, fuerza, relámpago, necrótico, veneno, psíquico, radiante y trueno. El suplemento por exceso también pertenece al componente físico y no escala con los dados adicionales. No se transforma el total del ataque en un único tipo de daño ni se aplica la tabla de placas al fuego.

Después de preparar esos importes, **Fantasy Grounds conserva la responsabilidad de aplicar las resistencias, inmunidades y vulnerabilidades por tipo**, incluidas las condiciones que pueda expresar su motor de efectos. Arms Bridge preserva `dmgtype` y sus etiquetas; no resta otra vez la resistencia ni escribe directamente puntos de golpe. Por ejemplo, una salida de 9 cortantes y 3 de fuego frente a resistencia al fuego debe acabar en 9 cortantes y 1 de fuego; inmunidad al daño cortante por sí sola no elimina el fuego de un impacto. Las reglas de referencia están en [D&D 2024: daño y resistencias](https://www.dndbeyond.com/sources/dnd/br-2024/playing-the-game#ResistanceandVulnerability). El resultado final dentro del programa está pendiente del ensayo descrito en `docs/SMOKE_TEST.md`.

La última fila deja de ser un techo de daño. Sea `I` el índice calculado, `L` el comienzo de la última fila de esa columna y `μ` la media de la suma de los dados base, excluyendo modificadores. Para un impacto completado, la prolongación añade:

`exceso = max(0, (I − L) / 5)`; `daño adicional = floor(μ × exceso / 10)`.

La pendiente inicial de esta alpha equivale a una media de los dados del arma por cada diez puntos del d20 que excedan ese umbral. El modificador de característica y los demás modificadores se suman una sola vez. El suplemento es daño del componente base, no una nueva tirada de dado con caras imposibles. Se aplica también a impactos ordinarios que superen el umbral gracias a una bonificación alta. Su progresión no tiene un máximo de reglas; los escalones provienen del redondeo a puntos de daño enteros.

**Los dados del crítico se dejan al sistema nativo de D&D y se añade el suplemento una sola vez.** Con el ejemplo anterior, un crítico ordinario conserva `2d8+3` cortantes y `2d4` de fuego, más el eventual suplemento cortante. No se maximiza además la base, no se duplican otra vez sus dados por cada nuevo 20 y no se multiplica el modificador plano. Un crítico por un rasgo que se active con 19 sigue siendo crítico; solo un 20 abre. No se crean efectos críticos de Rolemaster, tablas de pifias, sangrado, mutilaciones ni estados adicionales. Una calidad alta en un impacto ordinario no crea un crítico.

Ejemplo con la tabla `bladed`, columna `plate`, ataque `+5`, defensa adicional `0` y arma `1d8+3`. El comienzo de la última fila es 130, equivalente a una suma de d20 de 21 en este caso:

| Cadena | Suma | Exceso | Suplemento | Daño del arma con su crítico D&D |
|---|---:|---:|---:|---|
| `20+1` | 21 | 0 | +0 | `2d8+3` |
| `20+10` | 30 | 9 | +4 | `2d8+7` |
| `20+20+10` | 50 | 29 | +13 | `2d8+16` |
| `20+20+20+10` | 70 | 49 | +22 | `2d8+25` |

Con `2d6+3`, los mismos excesos añaden 0, 6, 20 y 34 porque la media de `2d6` es 7. Los dados críticos nativos siguen siendo aleatorios: lo que es monótono con el resultado abierto es el suplemento, y por tanto la esperanza del daño crítico, no necesariamente dos resultados independientes de sus dados.

Usar los dados del arma como escala no garantiza conservar el daño medio: una tabla puede producir demasiados percentiles altos o cambiar mucho la frecuencia de impactos, y la nueva prolongación añade daño a resultados elevados. La calibración compara **daño esperado por intento**, incluyendo fallos, críticos y la cola infinita, en diferentes bonificaciones, armaduras, dados y situaciones de ventaja. El objetivo admite diferencias tácticas entre familias y protecciones. Las curvas actuales necesitan calibración fina, especialmente con bonificaciones altas; `docs/BALANCE.md` recoge los resultados y no los presenta como un equilibrio ya conseguido.

Las familias incluidas son `blunted`, `bladed`, `axes`, `polearms`, `bows`, `crossbows`, `exotic` y `firearms`. Cada una ofrece `unarmored`, `leather`, `mail`, `plate`, `natural_hide`, `natural_scales` y `natural_shell`. Las equivalencias de armas y armaduras son aproximaciones para experimentar, no equivalencias oficiales entre los tipos de armadura de diferentes ediciones de Rolemaster.

Los perfiles de protección se basan en la construcción, no en la competencia ligera/media/pesada de D&D. `leather` agrupa acolchada, cuero, cuero tachonado y pieles; `mail` agrupa camisa de malla, cota de malla, anillas y escamas; `plate` agrupa coraza, semiplacas, laminada y placas completas. `unarmored` se asigna expresamente. Esta agrupación es todavía demasiado gruesa para una conversión terminada: si dos armaduras consultan la misma columna y se resta la CA material propia de cada una, se pierde la diferencia material entre ellas.

Por ejemplo, una laminada CA 17 y unas placas CA 18, sin otros bonos, consultan ambas `plate` con defensa adicional cero. En esta alpha dan el mismo resultado; la segunda no recibe automáticamente un +1 por su mejor construcción. Un +1 mágico sobre unas placas sí queda como defensa adicional uno. La corrección de diseño propuesta es separar subtipos mediante columnas distintas, manteniendo las tablas por familia de armas. El motor admite esas columnas adicionales mediante CSV, pero las curvas y asociaciones por defecto aún no distinguen esos subtipos.

Los perfiles naturales se asignan explícitamente. `natural_hide` representa piel gruesa o cuero natural; `natural_scales`, escamas; `natural_shell`, caparazón o placas naturales. Un animal sin protección material especial puede usar `unarmored`; carecer de armadura equipada no determina por sí solo ninguno de esos perfiles. Tampoco una CA alta permite distinguir protección, agilidad o magia. Tener escamas no concede resistencia al fuego: el perfil de protección y las resistencias del objetivo son datos independientes.

Los tres perfiles naturales tienen columnas editables independientes, pero sus curvas iniciales son copias de `leather`, `mail` y `plate`, respectivamente. Del mismo modo, `crossbows` y `firearms` parten de la forma de `bows`, y `exotic` parte de `bladed`. Estas semillas facilitan empezar a probar y modificar cada grupo; todavía no representan una calibración propia de penetración o de protección natural.

El catálogo adopta los ocho grupos solicitados y sus cuarenta armas:

| Grupo / identificador | Armas reconocidas por defecto |
|---|---|
| Blunted weapons / `blunted` | Club, Greatclub, Light Hammer, Mace, Flail, Morningstar, Warhammer, War Pick, Maul |
| Bladed weapons / `bladed` | Dagger, Sickle, Greatsword, Longsword, Shortsword, Scimitar, Rapier |
| Axes / `axes` | Handaxe, Battleaxe, Greataxe |
| Pole arms / `polearms` | Spear, Quarterstaff, Glaive, Halberd, Lance, Pike, Trident |
| Bows / `bows` | Shortbow, Longbow |
| Crossbows / `crossbows` | Hand Crossbow, Light Crossbow, Heavy Crossbow |
| Exotic / `exotic` | Javelin, Sling, Dart, Blowgun, Whip, Shuriken |
| Firearms / `firearms` | Pistol, Blunderbuss, Musket |

**La categoría, el grupo, el uso y el tipo de daño son atributos diferentes.** Un War Pick está en `blunted` según esta taxonomía y sigue siendo un arma marcial que causa daño perforante. Un Quarterstaff está en `polearms` y es simple. Las propiedades oficiales se contrastaron con [Equipment de D&D 2024](https://www.dndbeyond.com/sources/dnd/br-2024/equipment). Shuriken y Blunderbuss se registran como entradas de campaña: categoría `custom` y uso `unknown`, configurables sin inventar estadísticas. Los dados reales siempre proceden de la acción de Fantasy Grounds.

El uso `1h` o `2h` se captura al construir la acción. Un arma versátil no se asigna a dos manos por su nombre: si no hay información suficiente, el uso queda `unknown`. Categoría y manos no añaden multiplicadores al daño: usar `1d8` o `1d10` ya expresa el cambio de escala. Los ocho grupos comparten inicialmente su tabla entre usos; si se importa una tabla opcional como `bladed_2h`, se selecciona para ese uso. Armas sin alias, ataques naturales y acciones personalizadas requieren una asociación explícita.

La columna de maestrías de la propuesta no se instala como reglas nuevas. Su asignación por grupo no coincide con las maestrías individuales de las reglas oficiales 2024. La extensión conserva las maestrías y capacidades del anfitrión, sin sustituirlas por Parry, Keen, Fast Reload o Powerful ni conceder una propiedad por pertenecer a un grupo.

## 3. Configuración y controles

`/arms` abre el panel de modos e importación CSV. Los cambios de configuración corresponden al director de juego. Cada participante puede consultar el diagnóstico y descartar sus propios ataques pendientes.

| Comando | Uso |
|---|---|
| `/arms status` | Versión, modo efectivo, callbacks disponibles y último diagnóstico. |
| `/arms mode compare` | Muestra el cálculo alternativo y conserva el ataque y daño nativos. |
| `/arms mode on` | Aplica la resolución; requiere las capacidades detectadas. |
| `/arms mode off` | Desactiva la conversión. |
| `/arms actors` | Lista nombres y rutas del combat tracker. |
| `/arms armor "Nombre" plate 18` | Asigna el perfil y la CA base material del defensor. |
| `/arms armor "Nombre" unarmored 10` | Asigna explícitamente protección sin armadura. |
| `/arms armor "Nombre" natural_scales 16` | Asigna escamas naturales con CA base material 16. |
| `/arms armor "Nombre" auto` | Elimina la asignación manual y vuelve a detectar el equipo. |
| `/arms weapon "Nombre de acción" bladed` | Asocia una acción a una tabla. |
| `/arms weapon "Nombre de acción" bladed martial 1h` | Añade categoría y uso manual como alternativa cuando faltan datos de la acción. |
| `/arms weapon "Nombre de acción" bladed auto auto` | Elimina las dos alternativas manuales y conserva la asociación de tabla. |
| `/arms weapon "Nombre de acción" off` | Excluye esa acción de la conversión. |
| `/arms catalog` | Muestra los ocho grupos y el número de armas de cada uno. |
| `/arms catalog "Longsword" 2h` | Consulta categoría, grupo, propiedad, uso y tabla; no modifica la ficha. |
| `/arms tables` | Tablas, perfiles y procedencia de los datos cargados. |
| `/arms pending` | Estado de apertura o contextos listos en el cliente actual. |
| `/arms clear` | Descarta contextos; sus continuaciones posteriores no se reutilizan. |
| `/arms bypass` | Mantiene nativo el siguiente daño del cliente. |
| `/arms preview bladed mail 16 5 2 1d8+3` | Calcula un componente, sin hacer un ataque ni aplicar daño. |
| `/arms preview bladed plate 20+10 5 0 1d8+3` | Calcula una cadena abierta y su suplemento; admite más veintes. |

La detección automática usa una única armadura reconocida y equipada en el inventario del personaje. Resta su campo `ac` de la defensa efectiva del ataque. El bonus mágico, el escudo, la Destreza y los efectos que ya haya calculado Fantasy Grounds permanecen en la defensa adicional. Si hay varias armaduras equipadas o no puede identificarse su tipo, se requiere una asignación explícita.

Un valor de CA aislado de un monstruo no revela si procede de escamas, magia o agilidad. La extensión no adivina ese perfil: asigna los PNJ y los personajes sin armadura mediante `/arms armor`. El tercer argumento representa la parte material completa de la CA, **incluida la base de diez**; no es solamente su bonificación. Una armadura de placas ordinaria se configura con 18, no con 8.

Se reconocen nombres comunes de armas en inglés y algunos en español. Una asociación manual utiliza el nombre de la acción normalizado, ignorando mayúsculas, el sufijo mágico `+N` y las etiquetas `(1H)`, `(2H)` y `(OH)`. Las manos se conservan por separado en la identidad del ataque: un ataque a una mano no habilita la conversión de un daño solicitado a dos manos. Los ataques identificados expresamente como conjuros se excluyen incluso si tienen un nombre coincidente. Para nombres personalizados o acciones de PNJ sin indicador nativo de arma, utiliza una asociación manual.

La prioridad para el uso es: dato capturado de la acción, etiqueta de la acción, alternativa manual y propiedad fija del catálogo. En armas versátiles, lanzas de caballería o armas personalizadas sin un uso conocido se conserva `unknown`. Las alternativas manuales no cambian la competencia ni los dados de la ficha. El comando `preview` calcula una expresión de dados de un componente; no simula un ataque completo con varios tipos ni las resistencias de un actor.

## 4. Importar otras tablas

Abre `/arms`, pega un CSV completo y pulsa **Validar e importar**. La cabecera debe ser exactamente:

```csv
weapon,armor,min,max,hit,quality
training_sword,plate,0,89,false,0
training_sword,plate,90,109,true,0.25
training_sword,plate,110,129,true,0.60
training_sword,plate,130,,true,1
```

Este ejemplo es inventado y solo contiene el perfil `plate`. `examples/table-format.csv` contiene una tabla de ejemplo con los cuatro perfiles, lista para importar. Después puedes asociar una acción a `training_sword` con `/arms weapon "Longsword" training_sword`.

Los intervalos son enteros e inclusivos. Deben estar ordenados, sin huecos ni solapamientos, para cada pareja arma/armadura. La primera fila debe incluir el cero y ser un fallo con calidad cero; los índices inferiores se limitan a esa primera fila. La última fila deja `max` vacío para cubrir todos los valores superiores: su `min` es ahora el punto de partida de la prolongación de daño. `hit` acepta `true/false` o `1/0`; `quality` sigue entre cero y uno. Los CSV anteriores conservan su formato; a partir de 0.2.0 los impactos que superen el inicio de la última fila pueden añadir suplemento. Los naturales 1 y 20 conservan sus reglas incluso si la fila consultada indica otra cosa.

Todas las tablas de un CSV se validan antes de guardarlo. Importar un identificador de tabla existente sustituye **su definición completa**, no solo las columnas presentes. Incluye todos los perfiles que quieras conservar. Las importaciones se guardan en la campaña y se vuelven a cargar al abrirla. Se acepta un máximo de 256 KiB y 4.000 filas por importación.

Desde 0.3.0 se conservan los identificadores antiguos como alias: `sword → bladed`, `mace → blunted`, `spear → polearms`, `axe → axes` y `bow → bows`. Las asociaciones existentes y los CSV antiguos consultan la tabla canónica correspondiente. Un mismo CSV que mezcle dos nombres de la misma tabla, como `sword` y `bladed`, se rechaza íntegramente. En importaciones guardadas de lotes diferentes se mantiene el orden histórico de carga: la posterior sustituye la definición canónica completa, aunque use el otro nombre. Esto también afecta a una tabla personalizada antigua que ya se llamase como uno de los nuevos identificadores; revisa `/arms tables` después de actualizar. Nombres personalizados como `training_sword` no se renombran.

Este importador recibe tablas **ya adaptadas** a resultados de impacto/calidad. No hace OCR de libros ni decide por sí solo cómo convertir los puntos de daño y las letras de crítico de Arms Law. Se puede continuar el diseño con curvas originales por familias; incorporar datos concretos del manual es una opción que requiere transformarlos a este formato y calibrar esa transformación. El código de la extensión y el origen de los datos permanecen separados.

## 5. Límites de la versión alpha

Realiza cada ataque y su daño desde el mismo cliente, con un único objetivo. La calidad se asocia a atacante, defensor, identidad de arma y uso a una o dos manos. Cuando hay varios ataques pendientes indistinguibles de la misma arma contra el mismo objetivo, la conversión de daño se rechaza: resuelve ataque y daño de forma consecutiva o descarta los contextos con `/arms clear`. No se elige arbitrariamente una tirada anterior.

Espera a que termine la cadena de d20 antes de solicitar el daño. Esta alpha no retiene automáticamente una solicitud prematura: si llega mientras la tirada está abierta, conserva el daño nativo y descarta el contexto, con aviso, para no aplicar un suplemento incompleto ni reutilizarlo en otro daño. Las continuaciones llevan identificadores de uso único para que arrastrar o repetir una tirada no sume el mismo dado dos veces. `/arms clear`, cambiar de modo o cerrar la extensión invalidan los contextos pendientes.

Un lanzamiento de daño dirigido a varios objetivos conserva su resolución nativa; no aplica la calidad del último blanco a los demás. Cambiar de cliente entre ataque y daño, arrastrar un resultado antiguo a otro objetivo, cambiar la defensa después de resolver el ataque o repetir un daño de una forma que pierda su identidad necesita revisión manual. Los contextos son temporales y no sobreviven a una recarga de la campaña.

El suplemento se incorpora al preparar el daño, antes de lanzar sus dados. Una vez incorporado forma parte de ese lanzamiento; descartar después el contexto o rechazar una conversión de calidad tardía no lo revierte. En ese caso se conservan las caras nativas de los dados y el suplemento ya anunciado. Esta alpha no reconstruye una codificación de daño anterior para deshacer un lanzamiento en curso.

En impactos ordinarios se correlacionan los dados de la **primera cláusula física compatible**, aunque haya componentes elementales anteriores. Se excluyen como base los componentes expresamente marcados `critical`, `bCritical` o `precision`; esto no afirma que el sistema marque siempre Ataque furtivo como `precision`. Si la base del arma y otro daño físico carecen de marcas diferenciadoras, coloca primero la base. Los componentes adicionales separados —por ejemplo Ataque furtivo o un Smite— no se utilizan para multiplicar el exceso cuando están correctamente identificados u ordenados. Esto limita la correlación del daño total de ciertos personajes.

Una misma cláusula que mezcle tipos físicos y otros tipos de daño no proporciona importes separables: se conserva el daño nativo y se solicita corregir la configuración. También se conservan nativos los daños sin un componente físico identificable, las etiquetas físicas desconocidas y la base física sin dados. Por tanto, un arma de daño exclusivamente fijo, como la cerbatana ordinaria, todavía no recibe el suplemento creciente de esta versión. El catálogo reconoce el nombre, pero reconocer un arma no implica que todos sus formatos de daño admitan conversión. Una base exclusivamente elemental necesita un criterio de tablas propio antes de convertirse.

En los críticos los dados permanecen nativos y el suplemento se añade una sola vez. Las maestrías y capacidades siguen dependiendo del resultado comunicado al anfitrión; las automatizaciones que proporcione la instalación deben comprobarse allí. Esta alpha no añade un motor propio de maestrías, reacciones ni selección de recursos.

No hay límite de continuaciones o daño fijado por las reglas del módulo. Como cualquier programa, Lua dispone de memoria y precisión numérica finitas: si un resultado no puede representarse con seguridad, se notifica un error en lugar de recortarlo silenciosamente al máximo del arma o a una fila final.

La integración utiliza callbacks públicos observados en código de extensiones de 2026 y comprueba su disponibilidad. Los mocks verifican el contrato esperado, pero no reproducen todos los subsistemas internos de Fantasy Grounds. Hay que comprobar dentro del programa el orden del procesamiento de daño, las interfaces del panel, el modo multijugador y las extensiones que también alteren ataques o daño. `docs/SMOKE_TEST.md` incluye la secuencia concreta de comprobación.

## 6. Código, pruebas y empaquetado

La carpeta `extension` contiene únicamente los recursos del paquete instalable. `tests` contiene verificaciones independientes; `tools` contiene el ejecutor, el empaquetador reproducible y el análisis de las tablas. No hay bibliotecas externas que instalar para ejecutar la extensión.

Para verificar el proyecto desde su raíz:

```bash
python3 tools/test.py --require-lua
```

El ejecutor necesita Python 3.10 o posterior y un intérprete Lua, o una biblioteca compartida local Lua 5.2–5.4. En el entorno de desarrollo se utiliza `liblua5.4` mediante la API C y `ctypes`, sin instalar dependencias. Se comprueba la sintaxis de los archivos Lua, los scripts inline de XML, las referencias del paquete y las pruebas funcionales. La sintaxis de la extensión está escrita para Lua 5.1+, pero la ejecución automatizada realizada aquí usa Lua 5.4.

Para construir el paquete y el archivo de fuentes:

```bash
python3 tools/build.py
```

El resultado aparece en `dist/ArmsBridge.ext`, `dist/ArmsBridge-source.zip` y `dist/SHA256SUMS.txt`. El empaquetador ejecuta las pruebas y produce ZIP deterministas. Para repetir el análisis numérico con el mismo motor, usa `lua tools/analyze.lua` o `python3 tools/test.py --require-lua --test tools/analyze.lua`.

El código y los datos de demostración se distribuyen bajo MIT. Las referencias técnicas y sus límites de vigencia están documentados en `docs/INTEGRATION.md`. No se incluye código de los sistemas comerciales de Fantasy Grounds ni contenido de Iron Crown Enterprises.
