# Procedencia del manual y del arte

Este documento registra los materiales de **El nuevo Arms Law — Armas & armaduras**, el manual de campaña de Arms Bridge 0.3.1 alpha. La edición conservada tiene 52 páginas y cuarenta tablas de armas. La composición utiliza los PNG finales incluidos en el repositorio.

## Arte final aprobado

La ilustración de portada es la revisión 7 registrada en [data/image_manifest.json](data/image_manifest.json). Draknor se enfrenta al gólem de adamantita; Elarion, Melbick, Valkian, Vogun y Zephyrion completan el grupo de seis aventureros. Zephyrion está situado sobre una cornisa y apunta hacia el gólem. Valkian y Melbick se representan como gnomos de tamaño equivalente, conforme a la indicación de campaña.

El PNG aprobado de la portada es `assets/cover.png`. Su SHA-256 es:

```text
3629b0a293dd0a6095b789ffe9074c28da685b4f03e683036d03588418151110
```

El sello O.R.T.I.C.E. procede de `assets/logo.png` y se añade durante la maquetación. Su prompt conserva la petición de editar un emblema proporcionado en la sesión, cambiar la inscripción I.C.E. por O.R.T.I.C.E. y retirar el símbolo de marca registrada. La lámina `assets/party-reference.png` conserva la versión generada de los cinco compañeros utilizada para preparar la escena, incluida la corrección del tamaño de Valkian.

| Material conservado | Función |
|---|---|
| `assets/cover.png` | Ilustración final de portada |
| `assets/logo.png` | Sello de campaña O.R.T.I.C.E. |
| `assets/party-reference.png` | Lámina generada de referencia del grupo |
| `assets/blunted.png` | Contundentes |
| `assets/bladed.png` | Hojas |
| `assets/axes.png` | Hachas |
| `assets/polearms.png` | Armas de asta |
| `assets/bows.png` | Arcos |
| `assets/crossbows.png` | Ballestas |
| `assets/exotic.png` | Armas exóticas |
| `assets/firearms.png` | Armas de fuego |

## Cómo leer el manifiesto

El campo `generator` identifica la herramienta de generación utilizada. Cada entrada final conserva:

- `file`: ruta al PNG distribuido, relativa a `manual/`.
- `generation_id`: identificador histórico de su generación, sin depender de una ruta de la sesión.
- `sha256`: hash de los bytes del PNG.
- `prompt`: instrucciones conservadas de la generación o edición; las planchas también indican su distribución en filas y columnas.

La portada registra además su revisión y una `edit_reference`, identificada mediante hash y marcada `included: false`. Es una referencia de edición proporcionada durante la sesión, no una dependencia necesaria para construir el PDF.

`previous_covers` conserva los prompts, identificadores, hashes y notas disponibles de revisiones anteriores. Estas entradas están marcadas `included: false` y carecen de un campo `file`: no apuntan al PNG final ni incorporan los dibujos descartados. La numeración histórica solo se conserva donde estaba registrada.

**La reproducción del manual parte de los PNG guardados.** Los prompts documentan el proceso creativo y no constituyen un procedimiento determinista para regenerar esos mismos píxeles. La construcción ordinaria no vuelve a generar el arte ni modifica las imágenes. Las regiones de ilustración se recortan mediante máscaras en el PDF, conservando intactos los archivos fuente.

## Referencias de campaña

La escena se preparó con referencias de personajes indicadas durante la sesión:

- [Retrato de Draknor](https://dnd-companion.lorien.cloud/fg/avatar/draknor.png).
- [Página de personajes de la campaña](https://dnd-companion.lorien.cloud/fantasy-grounds/current-party/).

[data/party-references.json](data/party-references.json) conserva los nombres, las URL individuales y los hashes de los retratos consultados de Elarion, Melbick, Valkian, Vogun y Zephyrion. `included: false` indica que los retratos originales no se distribuyen. Sus tamaños y hashes describen las copias consultadas, no garantizan que una URL externa conserve siempre los mismos bytes. Los retratos descargados, el HTML de la página y los archivos originales aportados a la sesión no son entradas de la construcción.

## Datos, reglas y referencias editoriales

[data/weapons-sources.json](data/weapons-sources.json) identifica las fuentes oficiales consultadas el 8 de octubre de 2026 para los datos de las armas de D&D 2024. Conserva títulos, editor, URL, fecha de consulta y el alcance de cada fuente. Los nombres españoles y las notas de uso son redacción propia. Las agrupaciones son decisiones de campaña; las maestrías individuales son metadatos y mostrarlas no concede su uso. Los perfiles de shuriken y trabuco son propuestas de campaña identificadas en los datos.

Las tablas son la exportación de las curvas originales y experimentales del motor incluido en [extension/scripts/arms_engine.lua](../extension/scripts/arms_engine.lua). [data/tables.json](data/tables.json) registra su origen y versión; el exportador y el verificador están en [tools/](tools/). La referencia conceptual a Arms Law de Rolemaster Classic no convierte esas curvas en tablas oficiales de ICE. Las fuentes editoriales de consulta figuran también en el colofón de [data/manual_text.json](data/manual_text.json).

## Avisos y licencias

El alcance de la licencia MIT del proyecto es el indicado en [LICENSE](../LICENSE): código, documentación y datos de demostración originales. Su texto se conserva sin cambios. Esta nota registra la procedencia del material y no añade una concesión de derechos sobre referencias artísticas de terceros.

Las tipografías utilizadas para conservar la composición se distribuyen con sus propios avisos, procedencia y hashes en [fonts/manifest.json](fonts/manifest.json): cuatro estilos de Liberation Serif y los archivos AFM/PFB de URW Bookman Demi. Sus avisos están en [LICENSE-Liberation.txt](fonts/LICENSE-Liberation.txt) y [LICENSE-URW.txt](fonts/LICENSE-URW.txt), separados de la licencia del código.
