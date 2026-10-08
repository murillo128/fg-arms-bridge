# Simulador web de Arms Bridge

Aplicación estática en `docs/index.html`, implementada a partir del boceto de
campaña. Compara un ataque contra un objetivo usando las reglas básicas de D&D
2024 y las curvas originales experimentales del motor 0.3.1. No genera muestras
aleatorias, modifica la extensión ni publica una versión nueva del manual.

## Publicar con GitHub Pages

En el repositorio, abre **Settings → Pages → Build and deployment**. En **Source**
elige **Deploy from a branch**, selecciona la rama **main** y la carpeta **/docs**,
y pulsa **Save**. No selecciones la raíz ni GitHub Actions como fuente para este
procedimiento. El archivo `docs/.nojekyll` desactiva el procesamiento de Jekyll.

La dirección prevista, sin dominio personalizado, es:

https://murillo128.github.io/fg-arms-bridge/

La presencia de los archivos no activa por sí sola la configuración de Pages.
La página estará disponible cuando el propietario seleccione esa fuente y
termine el despliegue de Pages. Comprueba el enlace que presenta Settings → Pages
y la ejecución de Pages en Actions. Los cambios posteriores en `main /docs` se
publican automáticamente. El workflow `Simulator checks` valida el producto;
no es un workflow de despliegue y no solicita permisos de escritura.

Referencia: [configurar una fuente de publicación](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site).

## Uso y datos

La página funciona sin backend, cuentas, claves ni dependencias externas de
JavaScript. Todos los recursos usan rutas relativas compatibles con la subruta
del repositorio. Para utilizarla localmente, abre `docs/index.html` o sirve la
carpeta con `python3 -m http.server 8000 --directory docs`. Guardar y copiar enlaces
pueden estar restringidos por el navegador en archivos locales: utiliza HTTP
local o la dirección HTTPS de Pages para esos controles.

El atacante permite elegir las cuarenta armas del manual, su empuñadura válida,
Fuerza/Destreza, competencia y bonificaciones. Los bonos directos reemplazan los
calculados, no se suman a ellos. Cada componente adicional conserva expresión de
dados, tipo y elegibilidad para duplicar dados en crítico. Las constantes no se
duplican. Shuriken y trabuco están señalados como propuestas de campaña.

El defensor separa CA material y defensa adicional. El equipo aplica Destreza
completa, limitada a +2 o excluida según corresponda; una Destreza negativa sí
reduce la defensa con armadura media, pero no se aplica con pesada. Los modos
natural/manual requieren elegir expresamente su base, tratamiento de Destreza y
perfil de tabla. Escudo, magia y cobertura se añaden una vez. Las resistencias,
inmunidades y vulnerabilidades se configuran por tipo y no se deducen del material.

Las veinte filas se condicionan al d20 **inicial seleccionado**. Ventaja utiliza
probabilidad `(2r−1)/400`; desventaja, `(41−2r)/400`. Las métricas superiores incluyen
fallos y por ello son daño por intento, no daño por impacto ni por turno.
Selecciona una fila para ver su distribución y desglose por tipo. El 20 puede
inspeccionarse como mezcla completa o como cadena concreta de veintes y un dado
final entre 1 y 19. La pestaña de sensibilidad varía solo el bono al ataque.

Guardar utiliza `localStorage` del navegador. Compartir codifica exclusivamente
los campos admitidos en el fragmento `#s=` de la URL, validado al abrirlo. No hay
analítica ni peticiones a servicios. CSV exporta veinte filas con probabilidades,
mínimos, medias, máximos y diferencias; `Infinity` significa máximo no acotado.

## Método numérico

La distribución discreta se obtiene por convolución de dados independientes.
Los percentiles de los dados base se seleccionan comparando recuentos enteros
`BigInt`, evitando que un error de suma cambie el percentil 0,50 de 1d12 de 6 a 7.
Las probabilidades finales y las medias se representan en coma flotante de doble
precisión. Se agrupan los componentes del **mismo tipo** antes de aplicar sus
defensas y de convolucionar tipos diferentes. La resistencia se redondea en cada
resultado; la media de ese daño no se sustituye por la mitad de la media original.
El daño de cada tipo se limita inferiormente a cero, nunca se usa para curar.

La fila 20 incluye la cola geométrica completa. Sea `k` el número de veintes
adicionales tras el inicial y `j` el dado final (1–19). La suma es `20(k+1)+j` y la
probabilidad condicional de esa cadena concreta es `20^−(k+1)`. En el tramo abierto,
un nuevo 20 aumenta el suplemento en dos veces la media de los dados base.
Después de dos veintes, el incremento es un entero par: el redondeo de una
resistencia mantiene su paridad. Tras superar las posibles constantes negativas,
cada una de las dos subsecuencias tiene daño medio afín.

La implementación enumera un prefijo de al menos diez niveles y después suma
analíticamente ambas subsecuencias mediante las series geométrica y
aritmético-geométrica de razón `1/400`. El prefijo se amplía cuando hace falta para
salir del truncamiento inferior a cero. La **media no omite la cola**. Las gráficas
representan un prefijo finito, indican su masa residual y la incorporan en la
última barra agrupada. El máximo permanece infinito cuando el componente físico
creciente sobrevive a las defensas. Si es inmune o el arma tiene daño fijo, el
máximo aplicado es finito. El límite de 10.000 veintes del inspector protege la
interfaz: no es un tope usado en la distribución ni en la media.

Ejemplo inicial: espada larga +1, ataque +7, daño 1d8+4 cortante + 1d4 fuego,
semiplacas con Destreza +2 y resistencia al fuego. El d20=15 produce rango 5–14 y
media 9,50 en D&D; rango 8–10 y media 9,00 en Arms Bridge. Por intento, las medias
son 5,5125 y 4,315131578947368. La fila 20 tiene media 19,302631578947368 en el
modelo abierto, con máximo infinito y dados críticos nativos.

## Límites explícitos

Se estudia un ataque válido, con requisitos de alcance y competencia de armadura
ya resueltos. No se ejecutan efectos de maestría, dotes, salvaciones, cambios de
estado, repeticiones especiales de dados, bonificaciones aleatorias al ataque ni
ataques posteriores. Las maestrías del catálogo son informativas. Una advertencia
recuerda la desventaja por armas pesadas cuando falta la característica; el usuario
selecciona el modo neto. Los umbrales críticos 18/19 y la conversión de crítico en
normal son opciones que requieren un rasgo o regla aplicable, no beneficios
concedidos automáticamente. Esta última opción conserva el daño nativo no crítico
y el suplemento abierto, sin añadir además un percentil máximo.

Las defensas condicionales, por ejemplo resistencia solo a armas no mágicas, se
activan manualmente según el ataque. No se deducen de nombres de criaturas. Las
armaduras naturales y varias familias siguen usando las curvas iniciales. Se
preserva, y se advierte, que laminada CA 17 y placas CA 18 pueden consultar la misma
columna con la misma defensa adicional: la web no introduce una corrección de
combate distinta a la extensión. No se afirma calibración terminada ni compatibilidad
real con Fantasy Grounds por haber superado pruebas de JavaScript/Lua.

Para mantener el cálculo interactivo se admiten hasta seis componentes adicionales,
16 dados por expresión, caras de 2 a 100 y 500 caras sumadas por ataque antes de
crítico; los bonos numéricos tienen límites visibles en el formulario. Los errores
no se interpretan ni ejecutan como código y ocultan los resultados obsoletos.

## Fuentes, regeneración y pruebas

- [D&D 2024: equipo](https://www.dndbeyond.com/sources/dnd/br-2024/equipment).
- [D&D 2024: daño, críticos, resistencias](https://www.dndbeyond.com/sources/dnd/br-2024/playing-the-game).
- `extension/scripts/arms_engine.lua`: autoridad para la comparación Arms Bridge.
- `manual/data/weapons.json` y `manual/data/tables.json`: catálogo y exportación versionados.

`docs/simulator/data.js` es una exportación compacta, no otra tabla editada a mano.
Regenera con `python3 tools/export_simulator.py` después de actualizar los datos
del motor/manual. El logo web reutiliza el PNG final de `manual/assets/logo.png`;
conserva su procedencia y no implica afiliación editorial. No se añaden tipografías.

```sh
python3 tools/check_simulator.py
python3 -m pip install playwright==1.57.0
python3 -m playwright install chromium
python3 tools/test_simulator_browser.py
```

El primer comando exige Node (18 o posterior) y Lua mediante el backend existente
de `tools/test.py`. Comprueba exportación, 25 pruebas numéricas y 25.760 casos
contra el Lua real, con seis conjuntos de dados y suplementos por caso. El segundo
ensayo usa un origen HTTP local y un navegador real: controles, errores, guardado,
URL, CSV, modales, cadenas abiertas y maquetación a 390 px. El workflow aplica ambos
al cambiar el sitio o sus fuentes numéricas.

En entornos donde la navegación local esté bloqueada, la opción `--embedded`
permite comprobar DOM y renderizado a partir de los mismos archivos; informa
expresamente de que **no verifica HTTP, persistencia ni navegación por URL**. No
sustituye esa parte del ensayo predeterminado de CI. No se desactivan políticas del
navegador para realizar las pruebas.
