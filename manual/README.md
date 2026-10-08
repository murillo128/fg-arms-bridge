# El nuevo Arms Law — Armas & armaduras

Cuaderno ilustrado de campaña para D&D 2024, basado en las tablas originales y experimentales de **Arms Bridge 0.3.1 alpha**. La referencia conceptual es Arms Law de Rolemaster Classic. Este documento no reproduce las matrices de ICE ni constituye una edición oficial de Rolemaster o D&D.

La portada final muestra a Draknor enfrentándose a un gólem de adamantita, con sus cinco compañeros al fondo, Zephyrion sobre la cornisa y el sello de campaña O.R.T.I.C.E. Valkian y Melbick se representan como gnomos de tamaño equivalente, conforme a la indicación de campaña. Las referencias de la escena figuran en el manifiesto, en [PROVENANCE.md](PROVENANCE.md) y en el colofón.

## Contenido y construcción

El PDF A4 reúne las reglas de consulta, siete perfiles de protección, cuarenta páginas de armas con sus tablas, comandos de Fantasy Grounds, índice y fuentes. Las referencias de página se calculan desde la lista de páginas y el orden de las armas. La composición completa consta de **52 páginas**.

La [guía de construcción](../docs/BUILDING.md) explica cómo preparar Python 3.12, Lua 5.4 y las dependencias. Desde la raíz del repositorio, el comando de release valida y construye la extensión, el PDF y el archivo de fuentes:

```sh
python3 tools/build_release.py
```

La versión de distribución está en `../VERSION`: `0.3.1-alpha`. Los archivos versionados y `SHA256SUMS` se escriben en `../dist/release/`.

Para construir únicamente el manual, ejecuta desde esta carpeta:

```sh
python3 tools/verify_tables.py
python3 tools/build_book.py
```

El script genera:

- `output/pdf/El-nuevo-Arms-Law.pdf`.
- `tmp/pdfs/layout-audit.json`, con IDs de página, textos y cajas de tabla, regiones de ilustración, comprobaciones de ajuste y hashes de las fuentes.

Las dependencias Python están fijadas en [requirements.txt](requirements.txt). El constructor utiliza las tipografías incluidas en [fonts/](fonts/), con sus avisos y hashes, para conservar la composición. La tipografía de las tablas nunca baja de 9,5 puntos. El script rechaza textos demasiado anchos, párrafos que excedan su espacio, páginas incompletas o títulos de armas ausentes en la extracción final.

## Datos y arte

`data/weapons.json` aporta los nombres, estadísticas, propiedades, maestrías individuales y notas. `data/weapons-sources.json` conserva las fuentes consultadas y su alcance. `data/manual_text.json` aporta el texto del manual. `data/tables.json` contiene la exportación comprobada del motor: los totales ordinarios de cada celda incluyen el suplemento y excluyen M. Las variantes de una y dos manos se imprimen separadas por una barra. Los críticos conservan dados nativos + M + Δ; no utilizan el valor ordinario de la celda. La cerbatana mantiene el daño fijo nativo sin crecimiento. Shuriken y trabuco siguen siendo propuestas explícitas de campaña.

`data/image_manifest.json` identifica la portada y las planchas de armas. El constructor vuelve a leer los PNG en cada ejecución. Si existe `assets/logo.png`, incorpora ese sello de O.R.T.I.C.E. en la portada; puede indicarse otra ruta mediante `logo.file` en el manifiesto. El campo opcional `art_references` acepta referencias `{title, url, note}` para el colofón. **No recorta ni transforma los archivos de imagen**: embebe las planchas originales y muestra cada región con `clipPath` en el PDF. El análisis de píxeles sirve únicamente para medir el contorno de tinta y encajarlo. Las excepciones de región, cuando una ilustración cruza una división de la plancha, quedan registradas en el código y la auditoría. Las dos ballestas grandes usan polígonos para excluir dibujos vecinos sin cortar sus propios extremos.

Los once PNG de `assets/` son las fuentes de reproducción del arte. El manifiesto conserva sus hashes, identificadores de generación y prompts. La lámina `assets/party-reference.png` registra el diseño del grupo utilizado durante la preparación de la escena. `data/party-references.json` conserva metadatos y URL de los retratos externos; esos retratos no forman parte de las entradas del constructor. [PROVENANCE.md](PROVENANCE.md) explica la procedencia de los materiales. Conservar un prompt no implica poder regenerar exactamente la misma imagen.

Las fórmulas, estadísticas y curvas no se recalculan durante la maquetación. El exportador `tools/export_tables.lua` utiliza el motor incluido en la extensión. La revisión 0.3.1 corrige el percentil de 1d12 con calidad 0,50: corresponde a 6. La validación independiente mediante distribuciones exactas y aritmética racional está en `tools/verify_tables.py`.

## Revisión visual

Después de reconstruir, renderiza páginas con Poppler, por ejemplo:

```sh
python3 tools/build_book.py --render-qa
```

Esta opción reconstruye el PDF y genera `tmp/pdfs/final-cover.png`, `final-sources.png` y una hoja A2 con miniaturas de las 52 páginas en `contact-sheet.png`. La auditoría registra sus hashes y el PDF del que proceden. Para renderizar una página concreta:

```sh
pdftoppm -f 1 -l 1 -scale-to 1600 -png -singlefile output/pdf/El-nuevo-Arms-Law.pdf tmp/pdfs/cover
pdftoppm -f 21 -l 21 -scale-to 1600 -png -singlefile output/pdf/El-nuevo-Arms-Law.pdf tmp/pdfs/longsword
```

La auditoría geométrica complementa la revisión de imágenes: hay que comprobar la integridad de las armas, la legibilidad de las tablas y el encaje de portada y sello. Los PDF, archivos comprimidos, auditorías y renderizados se generan fuera del material fuente versionado. La integración de daño por tipos dentro de Fantasy Grounds continúa pendiente de la prueba real descrita en [SMOKE_TEST.md](../docs/SMOKE_TEST.md).
